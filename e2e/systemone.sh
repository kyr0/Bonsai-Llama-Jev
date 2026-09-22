#!/usr/bin/env bash
# Jev-like typed-decision query against the running llama-server (/v1/systemone).
# Why: proves the TypeSafe-compatible endpoint end to end — wire format, all
# three primitives (choice+score+noul fan-out), usage accounting, and the
# TypeSafe model list — without needing the SDK packages.
set -euo pipefail
PORT="${PORT:-5382}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${API_KEY}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "e2e-jev: server not running on :${PORT} — start it with: make start (or BONSAI_GGUF=/path/model.gguf make start)" >&2
  exit 1
fi

MODEL=$(curl -sf -m 5 -H "$AUTH" "$BASE/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])')
echo "e2e-jev: POST $BASE/v1/systemone (model=$MODEL, choice+score+noul fan-out)"
START=$(date +%s%N)
RESP=$(curl -sf -m 120 -X POST "$BASE/v1/systemone" -H "$AUTH" -H "Content-Type: application/json" -d @- <<JSON
{
  "model": "jev-latest",
  "state": {"ticket": "Hi, I've been trying to connect my Stripe account for 3 days and it keeps failing. I'm losing sales. Please help ASAP."},
  "questions": {
    "department": {
      "type": "choice",
      "instructions": "Which team should handle this?",
      "criteria": {
        "billing": "Payment or subscription issues",
        "technical": "Bugs or integration problems",
        "sales": "Pricing or account questions"
      }
    },
    "frustration": {
      "type": "score",
      "instructions": "How frustrated the customer appears",
      "criteria": ["Calm, just stating facts", "Frustrated but civil", "Very angry, strong language"]
    },
    "is_urgent": {
      "type": "noul",
      "instructions": "The message conveys urgency or time-sensitivity"
    }
  }
}
JSON
)
END=$(date +%s%N)

echo "$RESP" | MODEL="$MODEL" python3 -c '
import json, os, sys
r = json.load(sys.stdin)
assert r["model"] == os.environ["MODEL"], r["model"]
a = r["answers"]
assert set(a) == {"department", "frustration", "is_urgent"}, a.keys()
dept = a["department"]
assert dept["type"] == "choice" and dept["choice"] in ("billing", "technical", "sales"), dept
assert abs(sum(dept["probabilities"].values()) - 1.0) < 1e-6
assert 0.0 <= dept["confidence"] <= 1.0
fr = a["frustration"]
assert fr["type"] == "score" and 0.0 <= fr["score"] <= 2.0, fr
assert abs(sum(fr["probabilities"].values()) - 1.0) < 1e-6
assert set(a["is_urgent"]) == {"type", "noul"}
assert 0.0 <= a["is_urgent"]["noul"] <= 1.0
assert r["usage"]["input_tokens"] > 0 and r["usage"]["output_tokens"] == 0
print("e2e-jev: PASS " + json.dumps(a))
'
echo "e2e-jev: request latency $(( (END - START) / 1000000 ))ms"

# validation must be TypeSafe-shaped: 422 with error.code/message
CODE=$(curl -s -o /tmp/e2e-jev-err.json -w "%{http_code}" -X POST "$BASE/v1/systemone" \
  -H "$AUTH" -H "Content-Type: application/json" -d '{"state": "x"}')
python3 - "$CODE" <<'PY'
import json, sys
assert sys.argv[1] == "422", sys.argv[1]
err = json.load(open("/tmp/e2e-jev-err.json"))["error"]
# the server names the first missing required field ("model" here)
assert err["code"] == 422 and "model" in err["message"] and "required" in err["message"], err
print("e2e-jev: validation PASS (422, missing field named)")
PY
rm -f /tmp/e2e-jev-err.json

# Multimodal checks (shared with the openai suite): chat image_url + systemone media state.
bash "$SCRIPT_DIR/media.sh"
