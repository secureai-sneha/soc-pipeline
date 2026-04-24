import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
import urllib.request

# ─────────────────────────────────────────────────────────────────────────────
# LOGGER
# ─────────────────────────────────────────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel("INFO")

# ─────────────────────────────────────────────────────────────────────────────
# ENV CONFIG
# ─────────────────────────────────────────────────────────────────────────────
CANARY_ACCESS_KEY_ID = os.environ["CANARY_ACCESS_KEY_ID"]
SNS_TOPIC_ARN        = os.environ["SNS_TOPIC_ARN"]

GEOIP_API_URL        = os.environ.get("GEOIP_API_URL", "")
THREAT_INTEL_API_URL = os.environ.get("THREAT_INTEL_API_URL", "")
CHRONICLE_ENDPOINT   = os.environ.get("CHRONICLE_ENDPOINT", "")
SECRET_ARN           = os.environ.get("CHRONICLE_API_KEY_SECRET_ARN", "")

ENABLE_AUTO_RESPONSE = os.environ.get("ENABLE_AUTO_RESPONSE", "false").lower() == "true"

# ─────────────────────────────────────────────────────────────────────────────
# AWS CLIENTS
# ─────────────────────────────────────────────────────────────────────────────
sns     = boto3.client("sns")
sechub  = boto3.client("securityhub")
sts     = boto3.client("sts")
secrets = boto3.client("secretsmanager")
iam     = boto3.client("iam")

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def http_get(url, timeout=3):
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())

def http_post(url, data, headers, timeout=5):
    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode(),
        headers=headers,
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()

def get_secret():
    try:
        return secrets.get_secret_value(SecretId=SECRET_ARN)["SecretString"]
    except Exception as e:
        logger.error(f"Secret fetch failed: {e}")
        return None

def retry(func, retries=3):
    for i in range(retries):
        try:
            return func()
        except Exception as e:
            logger.warning(f"Retry {i+1} failed: {e}")
            time.sleep(2 ** i)
    return None

# ─────────────────────────────────────────────────────────────────────────────
# ENRICHMENT
# ─────────────────────────────────────────────────────────────────────────────

def geoip_lookup(ip):
    if not GEOIP_API_URL:
        return {}
    try:
        return http_get(f"{GEOIP_API_URL}/{ip}")
    except Exception as e:
        logger.warning(f"GeoIP failed: {e}")
        return {}

def threat_intel_lookup(ip):
    if not THREAT_INTEL_API_URL:
        return {}
    try:
        return http_get(f"{THREAT_INTEL_API_URL}/{ip}")
    except Exception as e:
        logger.warning(f"Threat intel failed: {e}")
        return {}

# ─────────────────────────────────────────────────────────────────────────────
# AUTO RESPONSE (SAFE)
# ─────────────────────────────────────────────────────────────────────────────

def revoke_key():
    try:
        iam.update_access_key(
            AccessKeyId=CANARY_ACCESS_KEY_ID,
            Status="Inactive"
        )
        logger.warning("Canary key revoked")
    except Exception as e:
        logger.error(f"Key revoke failed: {e}")

# ─────────────────────────────────────────────────────────────────────────────
# UDM MAPPING (Chronicle)
# ─────────────────────────────────────────────────────────────────────────────

def build_udm(event, geo, intel):
    detail = event["detail"]

    return {
        "metadata": {
            "event_type": "USER_RESOURCE_ACCESS",  
            "product_name": "AWS CloudTrail",
            "vendor_name": "AWS",
            "timestamp": detail.get("eventTime")
        },
        "principal": {
            "ip": detail.get("sourceIPAddress"),
            "user_agent": detail.get("userAgent"),
            "user": {
                "userid": detail.get("userIdentity", {}).get("accessKeyId"),
                "user_display_name": detail.get("userIdentity", {}).get("arn", "unknown")
            }
        },
        "target": {
            "resource_name": detail.get("eventSource"),
            "resource_type": "CLOUD_PROJECT",
            "application": detail.get("eventName")
        },
        "security_result": [{
            "action": "ALLOW",
            "severity": "CRITICAL",
            "threat_name": "Canary Credential Usage",
            "rule_name": "canary-credential-tripwire",
            "threat_feed_name": "internal-canary"
        }],
        "network": {
            "ip_protocol": "TCP",
            "direction": "INBOUND"
        },
        "additional": {
            "geo": geo,
            "threat_intel": intel,
            "aws_region": detail.get("awsRegion"),
            "aws_account_id": detail.get("recipientAccountId")
        }
    }

def push_chronicle(payload):
    if not CHRONICLE_ENDPOINT:
        return

    api_key = get_secret()
    if not api_key:
        return

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}"
    }

    retry(lambda: http_post(CHRONICLE_ENDPOINT, payload, headers))

# ─────────────────────────────────────────────────────────────────────────────
# MAIN HANDLER
# ─────────────────────────────────────────────────────────────────────────────

def lambda_handler(event, context):

    logger.info(json.dumps({"event": "lambda_invoked"}))

    detail = event.get("detail", {})
    used_key = detail.get("userIdentity", {}).get("accessKeyId")

    # VALIDATION
    if used_key != CANARY_ACCESS_KEY_ID:
        return {"status": "ignored"}

    # CONTEXT
    ip          = detail.get("sourceIPAddress", "unknown")
    user_agent  = detail.get("userAgent", "unknown")
    event_name  = detail.get("eventName", "unknown")
    event_src   = detail.get("eventSource", "unknown")
    region      = detail.get("awsRegion", "unknown")
    event_time  = detail.get("eventTime", datetime.now(timezone.utc).isoformat())

    logger.warning(json.dumps({
        "event": "CANARY_TRIGGERED",
        "ip": ip,
        "api": f"{event_src}/{event_name}"
    }))

    # ENRICHMENT
    geo   = geoip_lookup(ip)
    intel = threat_intel_lookup(ip)

    # SNS ALERT
    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=" Canary Credential Used",
            Message=json.dumps({
                "ip": ip,
                "api": f"{event_src}/{event_name}",
                "geo": geo,
                "threat_intel": intel
            }, indent=2)
        )
    except Exception as e:
        logger.error(f"SNS failed: {e}")

    # SECURITY HUB
    try:
        account_id = sts.get_caller_identity()["Account"]

        finding = {
            "SchemaVersion": "2018-10-08",
            "Id": f"canary-{CANARY_ACCESS_KEY_ID}-{event_time}",
            "ProductArn": f"arn:aws:securityhub:{region}:{account_id}:product/{account_id}/default",
            "AwsAccountId": account_id,
            "Types": ["TTPs/Credential Access"],
            "CreatedAt": event_time,
            "UpdatedAt": datetime.now(timezone.utc).isoformat(),
            "Severity": {"Label": "CRITICAL"},
            "Title": "Canary Credential Used",
            "Description": f"Used from {ip}",
            "Resources": [{
                "Type": "AwsIamAccessKey",
                "Id": CANARY_ACCESS_KEY_ID
            }]
        }

        sechub.batch_import_findings(Findings=[finding])

    except Exception as e:
        logger.error(f"SecurityHub failed: {e}")

    # CHRONICLE
    try:
        udm = build_udm(event, geo, intel)
        push_chronicle(udm)
    except Exception as e:
        logger.error(f"Chronicle failed: {e}")

    # SAFE AUTO RESPONSE
    if ENABLE_AUTO_RESPONSE:
        if intel.get("malicious", False):
            revoke_key()

    return {"status": "processed"}