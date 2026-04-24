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

print("=== INPUT ===")
print(json.dumps(sample, indent=2))

print("\n=== VALIDATING ===")
validate(sample)
print("Validation passed")

print("\n=== ENRICHING ===")
enriched = enrich(sample)
print("Enrichment done")

print("\n=== NORMALIZING ===")
output = normalize(enriched)
print("Normalization done")

print("\n=== FINAL OUTPUT ===")
print(json.dumps(output, indent=2))