# Deceptive Engineering Automation — Challenge 2

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Attacker uses canary AWS credential anywhere       │
│  (GitHub, CI/CD, developer machine, wiki, S3)       │
└──────────────────────┬──────────────────────────────┘
                       │ makes any AWS API call
                       ▼
┌─────────────────────────────────────────────────────┐
│  AWS CloudTrail                                     │
│  Records every API call across all regions          │
│  Delivers events to EventBridge within ~15 minutes  │
└──────────────────────┬──────────────────────────────┘
                       │ CloudTrail event
                       ▼
┌─────────────────────────────────────────────────────┐
│  Amazon EventBridge                                 │
│  Rule pattern: accessKeyId == CANARY_KEY_ID         │
│  Fires only when the specific canary key is seen    │
└──────────────────────┬──────────────────────────────┘
                       │ triggers immediately on match
                       ▼
┌─────────────────────────────────────────────────────┐
│  AWS Lambda (canary_response.py)                    │
│  1. Validates the trigger is genuine                │
│  2. Extracts attacker context from CloudTrail event │
│  3. Sends SNS alert to security team                │
│  4. Creates Security Hub finding                    │
└──────────┬──────────────────────┬───────────────────┘
           │                      │
           ▼                      ▼
┌──────────────────┐   ┌──────────────────────────────┐
│  Amazon SNS      │   │  AWS Security Hub            │
│  Email alert to  │   │  Formal finding created      │
│  security team   │   │  CRITICAL severity           │
│  with full       │   │  MITRE ATT&CK tagged         │
│  attacker context│   │  Tracked for investigation   │
└──────────────────┘   └──────────────────────────────┘
```

---

## Files in this submission

```
canary-detection/
├── canary.tf               — All AWS infrastructure
├── canary_variables.tf     — Input variables and outputs
└── terraform.tfvars        — Input variable values to customize deployments without modifying the core        configuration files
├── canary_response.py      — Lambda response logic
└── CANARY_README.md        — This file
└── RANKING.md              — Canary Credential Placement — Signal to Noise Ranking
└── requirements.txt        — Modules to be installed before executing code


```

---

## How to deploy

### Step 1 — Create the canary IAM user

Before running Terraform, manually create a canary IAM user with no
permissions attached. This user exists only as a tripwire.

```bash
# Create the user with no permissions
aws iam create-user --user-name canary-do-not-use

# Create an access key for this user
aws iam create-access-key --user-name canary-do-not-use
```

Note the `AccessKeyId` from the output. This is the `canary_access_key_id`.
Store the `SecretAccessKey` somewhere safe — as we need it to plant the canary
in the target locations.

### Step 2 — Enable Security Hub

The response Lambda creates findings in Security Hub. Enable it first:

```bash
aws securityhub enable-security-hub --enable-default-standards
```

### Step 3 — Deploy with Terraform

```bash
terraform init

terraform plan \
  -var="canary_access_key_id=AKIAIOSFODNN7EXAMPLE" \
  -var="alert_email=security@company.com"

terraform apply \
  -var="canary_access_key_id=AKIAIOSFODNN7EXAMPLE" \
  -var="alert_email=security@company.com"
```

### Step 4 — Confirm the SNS email subscription

After `terraform apply`, AWS sends a confirmation email to the address
you provided. Click the confirmation link or no alerts will be delivered.

### Step 5 — Plant the canary credentials

Place the canary access key ID and secret in your chosen locations.
The recommended format for each location:

**GitHub repository** — add a dummy `.aws/credentials` file:
```
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = YOUR_CANARY_SECRET_KEY
```

**CI/CD environment variable** — add as a pipeline secret named
`AWS_ACCESS_KEY_ID` in a non-production pipeline, or as a separate
variable named `CANARY_AWS_ACCESS_KEY_ID`.

**Developer `~/.aws/credentials`** — add a named profile:
```
[canary-do-not-use]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = YOUR_CANARY_SECRET_KEY
```

---

## How to test it works

Use the canary credentials to make a harmless API call:

```bash
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
AWS_SECRET_ACCESS_KEY=YOUR_CANARY_SECRET_KEY \
aws sts get-caller-identity
```

Wait up to 15 minutes (CloudTrail delivery latency) and you should receive:
- An email alert via SNS
- A new CRITICAL finding in the Security Hub console

---

## Important timing note

CloudTrail delivers events to EventBridge with a latency of up to 15 minutes
for management events. This means the alert will not be instantaneous in
production. For faster detection in a real deployment, you can additionally
set up a CloudWatch metric filter on CloudTrail logs to detect the canary
key within seconds, but that is outside the scope of this PoC.

---

## Safety design — why this cannot loop or false trigger

**No infinite loop:** The response Lambda uses its own IAM execution role
to call SNS and Security Hub. It never uses the canary key. Its own AWS
API calls therefore never match the EventBridge pattern and never
re-trigger themselves.

**No false triggers from Lambda itself:** The EventBridge pattern matches
on `userIdentity.accessKeyId` which is the key used to make the API call.
The Lambda's calls use a role-based session token, not an access key,
so they will never match the canary key pattern.

**Concurrency protection:** `reserved_concurrent_executions = 1` in
Terraform means if an attacker makes 50 rapid API calls, the Lambda
processes them one at a time rather than spinning up 50 simultaneous
invocations. This prevents alert storms.

**Validation gate:** The Lambda checks the access key ID before taking
any action. If EventBridge somehow fires for the wrong key, the Lambda
logs a warning and exits immediately without sending any alerts.
