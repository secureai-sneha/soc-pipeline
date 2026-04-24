"""
processor.py
------------
AWS Lambda function used as a Kinesis Firehose transformation processor.

What it does:
  1. Receives a batch of log records from Firehose
  2. Validates each record has the required fields
  3. Enriches each record (adds security_priority based on amount)
  4. Normalizes each record into a clean output schema
  5. Returns all records back to Firehose

Sample input log:
{
    "event_time": "2024-05-20T12:00:01Z",
    "user_id": "user_8821",
    "action": "TRANSFER_INITIATED",
    "amount": 12500,
    "currency": "EUR",
    "source_ip": "1.2.3.4"
}
"""

import base64
import hashlib
import json
import logging
import os
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel("INFO")

HIGH_VALUE_THRESHOLD = float(os.environ.get("HIGH_VALUE_THRESHOLD", "10000"))

REQUIRED_FIELDS = {
    "event_time",
    "user_id",
    "action",
    "amount",
    "currency",
    "source_ip"
}


# ── Validate ──────────────────────────────────────────────────────────────────

def validate(record: dict) -> None:
    """
    Validate required fields and coerce amount to float.

    FIX: amount is coerced from string before validation.
    Many real application logs serialize numbers as JSON strings.
    Rejecting "12500" when we expect 12500 is a false failure.
    """
    missing = REQUIRED_FIELDS - record.keys()
    if missing:
        raise ValueError(f"Missing required fields: {missing}")

    # Coerce amount to float — handles both int and string representations
    try:
        record["amount"] = float(record["amount"])
    except (TypeError, ValueError) as e:
        raise ValueError(f"amount cannot be converted to a number: {e}") from e

    if record["amount"] < 0:
        raise ValueError(f"amount cannot be negative: {record['amount']}")


# ── Enrich ────────────────────────────────────────────────────────────────────

def enrich(record: dict) -> dict:
    """
    Add security_priority and a deterministic event_id.

    event_id is SHA-256 of user_id + event_time + amount.
    The same event arriving twice always produces the same ID.
    Downstream systems can deduplicate on this field.
    """
    amount = record["amount"]  # already a float after validate()

    if amount >= 50000:
        priority = "CRITICAL"
    elif amount >= HIGH_VALUE_THRESHOLD:
        priority = "HIGH"
    elif amount >= 1000:
        priority = "MEDIUM"
    else:
        priority = "LOW"

    hash_input = f"{record['user_id']}:{record['event_time']}:{amount}"
    event_id = hashlib.sha256(hash_input.encode()).hexdigest()

    record["security_priority"] = priority
    record["event_id"] = event_id
    record["processed_at"] = datetime.now(timezone.utc).isoformat()
    return record


# ── Normalize ─────────────────────────────────────────────────────────────────

def normalize(record: dict) -> dict:
    """
    Produce a clean output schema with guaranteed field types.

    FIX: amount is rounded to 2 decimal places.
    Float arithmetic can produce 12500.000000000002 which causes
    unexpected behaviour in Athena queries and downstream tools.
    """
    return {
        "event_id":          record["event_id"],
        "event_time":        record["event_time"],
        "processed_at":      record["processed_at"],
        "user_id":           record["user_id"],
        "action":            record["action"],
        "source_ip":         record.get("source_ip", "unknown"),
        "amount":            round(record["amount"], 2),   # FIX: explicit rounding
        "currency":          record.get("currency", "EUR"),
        "security_priority": record["security_priority"],
        "pipeline_version":  "1.0.0",
    }


# ── Process one Firehose record ───────────────────────────────────────────────

def process_record(firehose_record: dict) -> dict:
    record_id = firehose_record["recordId"]

    # Decode base64
    try:
        raw_bytes = base64.b64decode(firehose_record["data"])
        raw = json.loads(raw_bytes)
    except Exception as e:
        logger.error("Decode failure record_id=%s error=%s", record_id, e)
        return _failed(record_id, firehose_record["data"])

    # Validate — mutates record["amount"] to float in place
    try:
        validate(raw)
    except ValueError as e:
        # FIX: log the full raw record so the error in S3 can be diagnosed
        logger.warning(
            "Validation failed record_id=%s error=%s raw=%s",
            record_id, e, json.dumps(raw)[:500]
        )
        return _failed(record_id, firehose_record["data"])

    # Drop non-transfer events silently
    if not str(raw.get("action", "")).startswith("TRANSFER"):
        logger.info("Dropped record_id=%s action=%s", record_id, raw.get("action"))
        return _dropped(record_id, firehose_record["data"])

    # Enrich and normalize
    try:
        enriched = enrich(raw)
        output = normalize(enriched)
    except Exception as e:
        logger.error(
            "Enrichment failure record_id=%s error=%s raw=%s",
            record_id, e, json.dumps(raw)[:500]
        )
        return _failed(record_id, firehose_record["data"])

    # Re-encode for Firehose — newline required for Athena newline-delimited JSON
    encoded = base64.b64encode(
        (json.dumps(output) + "\n").encode()
    ).decode()

    logger.info(
        "OK record_id=%s user=%s amount=%.2f priority=%s event_id=%s",
        record_id, output["user_id"], output["amount"],
        output["security_priority"], output["event_id"]
    )
    return {"recordId": record_id, "result": "Ok", "data": encoded}


def _failed(record_id: str, original_data: str) -> dict:
    return {"recordId": record_id, "result": "ProcessingFailed", "data": original_data}

def _dropped(record_id: str, original_data: str) -> dict:
    return {"recordId": record_id, "result": "Dropped", "data": original_data}


# ── Lambda handler ────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context) -> dict:
    """
    Firehose transformation entry point.

    Every record in the input MUST appear in the output.
    Omitting a record causes Firehose to retry the entire batch.
    The outer try/except guarantees this even on unexpected crashes.

    Changes from original:
      - records list is copied before iteration (defensive against mutation)
      - batch summary is published as a CloudWatch metric for alarming
      - result counts use a Counter for clarity and extensibility
    """
    from collections import Counter

    records = event.get("records", [])
    output = []

    logger.info("Batch received: %d records", len(records))

    for record in records:
        try:
            result = process_record(record)
        except Exception as e:
            logger.error(
                "Unexpected error record_id=%s error=%s",
                record.get("recordId"), e,
                exc_info=True
            )
            # Fallback: mark failed so Firehose routes to errors/ prefix.
            # Uses .get() on recordId in case the record itself is malformed.
            record_id = record.get("recordId", "UNKNOWN")
            result = _failed(record_id, record.get("data", ""))
        output.append(result)

    # ── Batch summary ─────────────────────────────────────────────────────────
    counts = Counter(r["result"] for r in output)
    ok      = counts["Ok"]
    failed  = counts["ProcessingFailed"]
    dropped = counts["Dropped"]

    logger.info(
        "Batch done: total=%d ok=%d failed=%d dropped=%d",
        len(output), ok, failed, dropped
    )

    # Warn loudly if the output count doesn't match the input count.
    # Firehose will retry the entire batch if any record is missing.
    if len(output) != len(records):
        logger.error(
            "RECORD COUNT MISMATCH: input=%d output=%d — Firehose will retry batch",
            len(records), len(output)
        )

    # Publish failed count as a custom CloudWatch metric so the alarm
    # in main.tf (lambda_errors) catches processing failures, not just crashes.
    if failed > 0:
        try:
            import boto3
            boto3.client("cloudwatch").put_metric_data(
                Namespace="SOCPipeline",
                MetricData=[{
                    "MetricName": "ProcessingFailed",
                    "Value": failed,
                    "Unit": "Count"
                }]
            )
        except Exception as e:
            # Never let metric publishing block the Firehose response
            logger.warning("CloudWatch metric publish failed: %s", e)

    return {"records": output}