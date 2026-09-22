#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${TYPESAFE_BASE_URL:-http://0.0.0.0:5380}"
API_KEY="${TYPESAFE_API_KEY:-local-dev-key}"

response="$({ curl -fsS -X POST "$BASE_URL/v1/systemone" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d @-; } <<'JSON'
{
  "state": "Hi, I've been trying to connect my Stripe account for 3 days and it keeps failing. I'm losing sales. Please help ASAP.",
  "model": "jev-latest",
  "questions": {
    "urgency": {
      "type": "noul",
      "instructions": "Does this message express urgency?"
    }
  }
}
JSON
)"

python3 - "$response" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["answers"]["urgency"]["type"] == "noul"
assert 0 <= payload["answers"]["urgency"]["noul"] <= 1
print("cURL documented request compatibility: OK")
PY
