#!/usr/bin/env bash
# Live performance probe against the running llama-server: current decode tok/s
# from one chat request, and decisions/sec from a burst of typed-decision
# requests. This measures right-now throughput on the live server - under load
# it reflects the loaded rate, on an idle server the idle rate.
set -euo pipefail
export LC_ALL=C  # dot decimals for curl %{time_total}
PORT="${PORT:-54100}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${API_KEY}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "metrics: server not running on :${PORT} - start it with: make start" >&2
  exit 1
fi

MODEL=$(curl -sf -m 5 -H "$AUTH" "$BASE/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])')

# slot occupancy for context
curl -sf -m 5 -H "$AUTH" "$BASE/slots" 2>/dev/null | python3 -c '
import json, sys
try:
    slots = json.load(sys.stdin)
    busy = sum(1 for s in slots if s.get("is_processing"))
    print(f"slots: {busy}/{len(slots)} busy")
except Exception:
    pass' || true

# tok/s: one chat request with a fixed generation budget
CHAT_BODY='{"messages": [{"role": "user", "content": "Count from 1 to 50, separated by commas."}], "max_tokens": 128}'
T_CHAT=$(curl -sf -m 120 -o "$TMP/chat.json" -w "%{time_total}" -X POST "$BASE/v1/chat/completions" -H "$AUTH" -H "Content-Type: application/json" -d "$CHAT_BODY")
python3 - "$TMP/chat.json" "$T_CHAT" <<'PY'
import json, sys
r, t = json.load(open(sys.argv[1])), float(sys.argv[2])
n = r["usage"]["completion_tokens"]
print(f"chat:  {n / t:.1f} tok/s  ({n} tokens in {t:.1f}s, incl. prefill)")
PY

# decisions/sec: burst of 8 concurrent typed-decision requests
ONE_BODY=$(MODEL="$MODEL" python3 <<'PY'
import json, os
print(json.dumps({
    "model": os.environ["MODEL"],
    "state": "My payouts have failed for three days, please help today.",
    "questions": {"department": {"type": "choice", "instructions": "Which team handles this?",
                                 "criteria": {"billing": "Payments", "technical": "Bugs"}}},
}))
PY
)
echo "metrics: firing 8 concurrent decision requests"
START=$EPOCHREALTIME
for i in $(seq 1 8); do
  curl -sf -m 60 -o "$TMP/one$i.json" -X POST "$BASE/v1/systemone" -H "$AUTH" -H "Content-Type: application/json" -d "$ONE_BODY" &
done
wait
WALL=$(python3 -c "print($EPOCHREALTIME - $START)")
python3 - "$TMP" "$WALL" <<'PY'
import json, sys
tmp, wall = sys.argv[1], float(sys.argv[2])
n = 0
for i in range(1, 9):
    r = json.load(open(f"{tmp}/one{i}.json"))
    assert "department" in r["answers"], r
    n += 1
print(f"decision: {n / wall:.1f} decisions/s  ({n} concurrent in {wall:.2f}s)")
PY
