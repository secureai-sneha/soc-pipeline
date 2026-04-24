# Unified Security Telemetry & Detection Platform

A scalable AWS-native platform that centralizes application telemetry and attacker signals into a unified S3 data lake for security analytics and automated response.

##  Overview

This system combines two complementary security capabilities:

### 1. Secure Logging Pipeline (Challenge 1)
Ingests money transfer logs → validates/enriches → normalizes → stores in S3 data lake for Athena querying.

### 2. Canary Token Detection (Challenge 2)
Deploys deceptive AWS credentials → detects usage via CloudTrail → triggers automated security response.

**Core Design Principle**: All security signals (business + attacker activity) flow into one structured, queryable data lake enabling unified investigation, low-noise detection, and correlation analysis.

##  Architecture Overview
TELEMETRY PIPELINE (Application Logs)
Money Transfer Lambda
↓ writes JSON logs
CloudWatch Logs → Subscription Filter (TRANSFER_* only)
↓ Kinesis Data Firehose (buffer + retry)
↓ Enrichment Lambda (processor.py)
├── S3 Data Lake (year/month/day/hour partitioned)
└──  S3 errors/ prefix
↓ Amazon Athena (query + analytics)

DETECTION PIPELINE (Canary Tokens)
Attacker uses canary AWS credential
↓ CloudTrail (API call record)
↓ EventBridge (match: canary_access_key_id)
↓ Response Lambda (canary_response.py)
├── Send SNS alert
├── Create Security Hub CRITICAL finding
└── (Optional) → S3 Data Lake


##  Challenge 1: Secure Logging Pipeline

### Processing Flow
CloudWatch Logs → Firehose → Lambda (validate/enrich/normalize) → S3

text

### Sample Input/Output

**Raw Input:**
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

**Normalized Output:**
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

### Security Priority Thresholds
| Priority  | Amount (EUR) |
|-----------|--------------|
| CRITICAL  | ≥ 50,000     |
| HIGH      | ≥ 10,000     |
| MEDIUM    | ≥ 1,000      |
| LOW       | < 1,000      |

### Reliability Features
- **At-least-once delivery** (Firehose retries Lambda 3x)
- **Deduplication**: `event_id = SHA256(user_id + event_time + amount)`
- **Error storage**: `s3://bucket/errors/ProcessingFailed/year=YYYY/month=MM/`
- **S3 delivery**: 24-hour retry window

##  Challenge 2: Canary Token Detection & Response

### Deployment Strategy (Signal-to-Noise)
| Location                | Signal Quality | False Positive Risk |
|-------------------------|----------------|--------------------|
| CI/CD environment vars  | ⭐⭐⭐⭐⭐         | Near-zero         |
| Developer ~/.aws/       | ⭐⭐⭐⭐          | Rare accidental   |
| Dormant S3 bucket       | ⭐⭐⭐           | Scanner noise     |
| Internal wiki           | ⭐⭐            | Internal access   |
| Public GitHub           | ⭐             | Bot triggers      |

### Detection & Response Flow
CloudTrail captures API call with canary access_key_id

EventBridge matches exact access_key_id

Lambda extracts: IP, API, region, user-agent

Actions:

SNS alert to security team

Security Hub CRITICAL finding

(Optional) Forward to S3 data lake

text

**Timing Note**: CloudTrail → EventBridge latency: ~15 minutes

### Safety Controls
- No infinite loops or self-triggering
- Lambda concurrency limits
- Event validation gate
- No legitimate credential overlap

##  Unified Data Lake Benefits

**Both pipelines produce Athena-queryable JSON:**

```sql
-- Correlate high-value transfers with canary triggers
SELECT 
  user_id, 
  amount, 
  security_priority, 
  event_time,
  canary_ip_address
FROM transfer_logs 
WHERE security_priority IN ('HIGH', 'CRITICAL')
ORDER BY amount DESC;
```

##  Monitoring Dashboard

### Pipeline Health Metrics
Firehose DataFreshness

Lambda Errors/Duration/Throttles

errors/ prefix file count

S3 delivery success rate

text

### Security Signals
HIGH/CRITICAL transaction volume

Canary trigger events per day

Baseline deviation alerts

text

##  Repository Structure
soc-platform/
├── main.tf # Terraform infrastructure
├── variables.tf # Input variables
├── terraform.tfvars # Environment values
├── processor.py # Log enrichment Lambda
├── canary_response.py # Canary detection Lambda
├── test_lambda.py # Unit tests
├── RANKING.md # Solution evaluation
└── README.md # This document

text

##  Design Decisions

| Component | Choice | Rationale | Tradeoff |
|-----------|--------|-----------|----------|
| Ingestion | Firehose | Managed buffering/retry | Simplicity vs Streams flexibility |
| Processing | Lambda | Full validation control | Code vs managed transforms |
| Delivery | At-least-once | Maximum durability | Query-time deduplication |
| Detection | Canary tokens | Highest confidence signals | Limited attack surface coverage |


##  Planned Enhancements
- Parquet conversion for query cost savings
- GeoIP + threat intelligence enrichment
- Schema registry with versioning
- DynamoDB stateful deduplication
- Direct SIEM ingestion (Chronicle/Splunk)

##  The following criteria have beeen Met
1. **High-quality structured data** in partitioned S3 lake
2. **High-confidence attacker detection** via canary tokens
3. **Unified investigation capability** across all signals
4.  **Automated incident response** with Security Hub integration
5.  **Scalable analytics** via Amazon Athena  

---
*Built for production-grade security operations at scale*
