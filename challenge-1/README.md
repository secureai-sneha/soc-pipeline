# The Secure Pipe Architect

## What this does

This pipeline automatically ingests money transfer logs from AWS CloudWatch,
enriches them with a security priority flag, normalizes them into a clean
schema, and stores them in an S3 data lake for long-term Athena querying.

---

## Architecture

```
┌─────────────────────────┐
│  Money Transfer Service │  (your application)
│  AWS Lambda             │
└────────────┬────────────┘
             │ writes JSON logs
             ▼
┌─────────────────────────┐
│  CloudWatch Logs        │  collects all application logs
│                         │
│  Subscription Filter    │  forwards only TRANSFER_* events
└────────────┬────────────┘
             │ TRANSFER events only
             ▼
┌─────────────────────────┐
│  Kinesis Data Firehose  │  buffers records (5 MB or 60 seconds)
│                         │  retries on failure (up to 3 times)
└────────────┬────────────┘
             │ batch of records
             ▼
┌─────────────────────────┐
│  Enrichment Lambda      │  1. validates schema
│  (processor.py)         │  2. enriches with security_priority
│                         │  3. normalizes to clean output schema
└────────┬────────┬────────┘
         │        │
    Ok   │        │ ProcessingFailed
         ▼        ▼
┌──────────────┐  ┌──────────────────────┐
│  S3 Data     │  │  S3 errors/ prefix   │
│  Lake        │  │  (failed records for │
│  logs/year=… │  │   investigation)     │
└──────────────┘  └──────────────────────┘
         │
         ▼
┌─────────────────────────┐
│  Amazon Athena          │  SQL queries over the data lake
└─────────────────────────┘
```

### Why each component was chosen

**Kinesis Data Firehose** — handles buffering, retries, S3 delivery, and Lambda
transformation without any consumer management. The right choice for log
delivery where sub-second latency is not required.

**Lambda as the transformation function** — gives full Python control over
validation, enrichment logic, and schema normalization. Cannot be replaced by
Firehose's built-in processing for custom business logic.

**S3 with Hive partitioning** (`year=/month=/day=/hour=`) — Athena only scans
the partitions that match your query's WHERE clause. A query for today's HIGH
priority transfers reads only today's files, not the entire dataset.

**CloudWatch Subscription Filter** — filters noise at the source. Only
`TRANSFER_*` events enter the pipeline. Health checks and other events are
discarded before consuming any Firehose capacity.

---

## Sample input and output

**Input** (raw log from the application):
```json
{
  "event_time": "2024-05-20T12:00:01Z",
  "user_id": "user_8821",
  "action": "TRANSFER_INITIATED",
  "amount": 12500,
  "currency": "EUR",
  "source_ip": "1.2.3.4"
}
```

**Output** (enriched and normalized, stored in S3):
```json
{
  "event_id": "a3f8c2d19e4b...",
  "event_time": "2024-05-20T12:00:01Z",
  "processed_at": "2024-05-20T12:00:04Z",
  "user_id": "user_8821",
  "action": "TRANSFER_INITIATED",
  "source_ip": "1.2.3.4",
  "amount": 12500.0,
  "currency": "EUR",
  "security_priority": "HIGH",
  "pipeline_version": "1.0.0"
}
```

The `security_priority` is set to `HIGH` because 12,500 EUR exceeds the
10,000 EUR threshold. The `event_id` is a SHA-256 hash of the user ID,
event time, and amount — used for deduplication.

**Priority thresholds:**

| Priority | Amount (EUR)       |
|----------|--------------------|
| CRITICAL | 50,000 or above    |
| HIGH     | 10,000 or above    |
| MEDIUM   | 1,000 or above     |
| LOW      | Everything else    |

---

## At-least-once delivery and retries

**What at-least-once means:** Every record is guaranteed to reach S3
eventually. Under failure conditions the same record may arrive more than
once. This is normal and expected for any streaming pipeline.

**How retries work at each layer:**

*Firehose → Lambda:* Firehose retries a failed Lambda invocation up to 3
times. If all 3 retries fail, the record is written to the `errors/` S3
prefix. No record is ever silently lost.

*Lambda contract:* Firehose requires that every record in the input batch
appears in the output. If the Lambda crashes or omits a record, Firehose
retries the entire batch — which would create duplicates for all the other
records. The processor's outer `try/except` in `lambda_handler` guarantees
every record always gets a result, even on unexpected errors.

*Firehose → S3:* Firehose has a built-in 24-hour retry window for S3
delivery failures. Records are never dropped due to a temporary S3 outage.

**How duplicates are handled:**

Because retries can send the same record more than once, every record is
assigned a deterministic `event_id` computed as:

```
event_id = SHA-256(user_id + event_time + amount)
```

The same record arriving twice always produces the same `event_id`. Athena
queries can deduplicate on this field:

```sql
SELECT DISTINCT event_id, user_id, amount, security_priority
FROM transfer_logs
WHERE security_priority = 'HIGH';
```

**Error records:**

Records that fail validation or processing land in the S3 `errors/` prefix:
```
s3://soc-pipeline-data-lake/errors/ProcessingFailed/year=2024/month=05/
```
These can be inspected, fixed, and replayed manually once the root cause
is identified.

---

## Monitoring — key metrics

### Firehose metrics (in CloudWatch under AWS/Firehose)

| Metric | What to alert on | What it means if breached |
|---|---|---|
| `DeliveryToS3.DataFreshness` | > 300 seconds | Lambda is slow or throttled — records backing up |
| `DeliveryToS3.Success` | < 0.99 for 2 minutes | S3 delivery is failing — records going to errors/ |

### Lambda metrics (in CloudWatch under AWS/Lambda)

| Metric | What to alert on | What it means if breached |
|---|---|---|
| `Errors` | Any error | Bug in the processor or upstream schema change |
| `Duration` | p99 > 270 seconds | Approaching Firehose's 300-second timeout limit |
| `Throttles` | Any throttle | Reserved concurrency too low — records waiting |

### How to monitor pipeline health day-to-day

1. **Records in errors/ prefix** — set an S3 event notification to send an
   SNS alert whenever a file lands in the `errors/` prefix. This is the
   clearest signal that something is wrong.

2. **Firehose DataFreshness** — if this metric grows steadily over time, the
   Lambda processor is too slow or concurrency is exhausted. Check Lambda
   duration and throttle metrics next.

3. **Security-specific monitoring** — create a CloudWatch metric filter on
   Lambda logs that counts records with `security_priority = HIGH` or
   `CRITICAL` per 5-minute window. Alert if this count is unusually high
   compared to the previous 7-day average. A sudden spike may indicate
   a fraud attempt or a bug in the upstream application sending wrong amounts.

---

## Files in this submission

```
soc-pipeline/
├── main.tf         — S3, Firehose, Lambda, IAM, Subscription Filter
├── variables.tf    — input variables and outputs
├── processor.py    — Lambda enrichment and normalization logic
└── README.md       — this file
```

## How to test locally (no AWS needed)

Save this as `test_local.py` in the same folder as `processor.py` and run it:

```python
import json
from processor import validate, enrich, normalize

sample = {
    "event_time": "2024-05-20T12:00:01Z",
    "user_id": "user_8821",
    "action": "TRANSFER_INITIATED",
    "amount": 12500,
    "currency": "EUR",
    "source_ip": "1.2.3.4"
}

validate(sample)
enriched = enrich(sample)
output = normalize(enriched)
print(json.dumps(output, indent=2))
```

```bash
python test_local.py
```

Expected output:
```json
{
  "event_id": "...",
  "event_time": "2024-05-20T12:00:01Z",
  "processed_at": "...",
  "user_id": "user_8821",
  "action": "TRANSFER_INITIATED",
  "source_ip": "1.2.3.4",
  "amount": 12500.0,
  "currency": "EUR",
  "security_priority": "HIGH",
  "pipeline_version": "1.0.0"
}
```

## Athena query example

After deployment, use this SQL in Athena to query the data lake:

```sql
-- Create the table (run once)
CREATE EXTERNAL TABLE transfer_logs (
  event_id          STRING,
  event_time        STRING,
  processed_at      STRING,
  user_id           STRING,
  action            STRING,
  source_ip         STRING,
  amount            DOUBLE,
  currency          STRING,
  security_priority STRING,
  pipeline_version  STRING
)
PARTITIONED BY (year STRING, month STRING, day STRING, hour STRING)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
LOCATION 's3://soc-pipeline-data-lake/logs/'
TBLPROPERTIES ('has_encrypted_data'='true');

-- Load partitions
MSCK REPAIR TABLE transfer_logs;

-- Query: all HIGH and CRITICAL transfers
SELECT user_id, amount, security_priority, event_time, source_ip
FROM transfer_logs
WHERE security_priority IN ('HIGH', 'CRITICAL')
ORDER BY amount DESC;
```
