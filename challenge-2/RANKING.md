# Canary Credential Placement — Signal to Noise Ranking

## What signal-to-noise ratio means here

A high signal-to-noise ratio means:
- When the canary fires, it almost certainly indicates real attacker activity
- False positives (legitimate accidental use) are extremely rare

A low signal-to-noise ratio means:
- Alerts may be triggered by benign or accidental actions
- It becomes harder to distinguish real threats from noise

---

## Ranked: Highest to Lowest Signal-to-Noise

---

### 1. Production CI/CD Pipeline Environment Variable
**Signal-to-noise: HIGHEST**

**Why the signal is high:**

CI/CD systems (GitHub Actions, GitLab CI, Jenkins) are prime targets in modern attacks. Secrets stored as environment variables are frequently exfiltrated during supply chain compromises.

If a canary credential is accessed here, it strongly indicates:
- Pipeline compromise
- Malicious insider activity
- Exploitation of CI/CD misconfiguration

**Expected attacker behaviour:**
- Extract environment variables from pipeline config or logs
- Validate credentials using `sts:GetCallerIdentity`
- Attempt privilege enumeration

**False positive risk: VERY LOW**

Mitigation:
- Use obvious naming like `CANARY_DO_NOT_USE_AWS_KEY`
- Add comments indicating it is a security tripwire

---

### 2. Public GitHub Repository
**Signal-to-noise: HIGH**

**Why the signal is high:**

Public repositories are continuously scanned by:
- Attackers
- Bots (TruffleHog, GitGuardian)
- Secret scanning services

Exposure leads to near-instant detection and use.

**Expected attacker behaviour:**
- Discover key via commit or history
- Validate via `sts:GetCallerIdentity`
- Attempt enumeration (`iam`, `s3`, `ec2`)

**False positive risk: LOW**

Mitigation:
- Never embed canary in production code
- Use clearly fake/dummy credential context

---

### 3. Developer `~/.aws/credentials`
**Signal-to-noise: HIGH (but delayed)**

**Why the signal is high:**

This file is the first target in:
- Malware
- Post-exploitation scripts
- Red team tooling

Indicates endpoint compromise.

**Expected attacker behaviour:**
- Dump AWS profiles
- Attempt usage of discovered keys

**False positive risk: MEDIUM**

Mitigation:
- Use profile name like: [do-not-use-canary-tripwire]


---

### 4. Internal IT Wiki
**Signal-to-noise: MEDIUM**

**Why the signal is medium:**

Accessible internally → useful for:
- Insider threat detection
- Compromised SSO sessions

But detection occurs **late in attack chain**.

**Expected attacker behaviour:**
- Search wiki for “AWS credentials”
- Copy and test key

**False positive risk: MEDIUM–HIGH**

Mitigation:
- Add strong visible warning:
> ⚠️ THIS IS A SECURITY TRIPWIRE — DO NOT USE

---

### 5. Dormant S3 Bucket
**Signal-to-noise: LOWEST**

**Why the signal is low:**

- Hard to discover
- Requires deep access already

Acts as **late-stage detection**.

**Expected attacker behaviour:**
- Enumerate buckets
- Read contents
- Discover credentials

**False positive risk: HIGH**

Mitigation:
- Ensure no legitimate workloads access bucket
- Monitor access patterns carefully

---

## Summary Table

| Location | Signal-to-Noise | False Positive Risk | Attack Stage Detected |
|--------|----------------|-------------------|----------------------|
| CI/CD environment variable | Highest | Very low | Initial access / supply chain |
| Public GitHub repository | High | Low | Credential exposure |
| Developer credentials file | High | Medium | Endpoint compromise |
| Internal IT wiki | Medium | Medium-high | Insider / lateral movement |
| Dormant S3 bucket | Lowest | High | Deep lateral movement |

---

## Key Takeaways

- Canary placement determines detection quality more than detection logic
- Best placements detect **early-stage attacker activity**
- Combine multiple placements for **defense-in-depth**
- Always optimize for:
- Low false positives
- High attacker likelihood
- Fast detection time

---

## Recommended Strategy

For production environments:

1. CI/CD pipeline (primary detection)
2. Public repo monitoring (external exposure)
3. Developer endpoints (compromise detection)

Optional:
- Internal wiki (insider detection)
- S3 bucket (deep threat detection)

---

## Final Insight

A well-placed canary credential is not just a detector—it is an **early warning system for real-world attack paths**.

The closer your placement aligns with actual attacker behavior, the more valuable your signal becomes.

