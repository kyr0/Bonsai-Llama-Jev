#!/usr/bin/env bash
# Fires long chat generations and then, mid-generation, typed-decision requests
# (/v1/systemone) at the running server.
# Why: proves the two endpoints run concurrently and that decisions are
# prioritized — the decision requests arrive staggered (not at the same time
# as the chats) yet must finish before the still-running chats complete.
set -euo pipefail
export LC_ALL=C  # dot decimals for EPOCHREALTIME / curl %{time_total}
PORT="${PORT:-54100}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${API_KEY}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "e2e-concurrent: server not running on :${PORT} — start it with: make start" >&2
  exit 1
fi

MODEL=$(curl -sf -m 5 -H "$AUTH" "$BASE/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])')

# calibrate decode rate from the server-reported decode timing of one tiny chat
# (thinking off, else a truncated budget lands entirely in reasoning_content)
CAL_BODY='{"messages": [{"role": "user", "content": "Count from 1 to 30, separated by commas."}], "chat_template_kwargs": {"enable_thinking": false}, "max_tokens": 9}'
CAL_JSON=$(curl -sf -m 60 -X POST "$BASE/v1/chat/completions" -H "$AUTH" -H "Content-Type: application/json" -d "$CAL_BODY")

# chats sized for ~8s of generation at that rate: still running when the
# decisions land on fast GPUs, finished in time on slow CPU boxes; the count
# prompt is longer than any max_tokens cap, so generation runs to the cap
read -r MAX_TOKENS CHAT_TIMEOUT <<< "$(CAL_JSON="$CAL_JSON" python3 <<'PY'
import json, os
r = max(float(json.loads(os.environ["CAL_JSON"])["timings"]["predicted_per_second"]), 0.1)
mt = max(16, min(2048, round(r * 8)))
print(mt, max(120, round(mt / r * 6)))
PY
)"
CHAT_BODY='{"messages": [{"role": "user", "content": "Count from 1 to 1000, separated by commas."}], "chat_template_kwargs": {"enable_thinking": false}, "max_tokens": '"$MAX_TOKENS"'}'
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

req_bg() { # $1=out.json  $2=endpoint  $3=body — records absolute end time in $1.end
  ( curl -sf -m "$CHAT_TIMEOUT" -o "$1" -X POST "$BASE/$2" -H "$AUTH" -H "Content-Type: application/json" -d "$3"
    echo "$EPOCHREALTIME" > "$1.end" ) &
}

echo "e2e-concurrent: firing 2 chat requests, decisions follow mid-generation (model=$MODEL, chat max_tokens=$MAX_TOKENS)"
START=$EPOCHREALTIME
for i in 1 2; do req_bg "$TMP/c_chat$i.json" v1/chat/completions "$CHAT_BODY"; done

sleep 1.0  # chats are mid-generation; decisions must not wait for them
for i in 1 2; do req_bg "$TMP/c_one$i.json" v1/systemone "$ONE_BODY"; done

wait

python3 - "$TMP" "$START" <<'PY'
import json, os, sys
tmp, start = sys.argv[1], float(sys.argv[2])

for n in ("c_chat1", "c_chat2", "c_one1", "c_one2"):
    assert os.path.exists(f"{tmp}/{n}.json"), f"missing response {tmp}/{n}.json (request timed out or failed)"

def chat(path):
    r = json.load(open(path))
    content = r["choices"][0]["message"]["content"]
    assert isinstance(content, str) and content.strip(), "empty chat content"
    return content

def one(path):
    r = json.load(open(path))
    d = r["answers"]["department"]
    assert d["type"] == "choice" and d["choice"] in ("billing", "technical"), d
    return d["choice"]

for i in (1, 2):
    chat(f"{tmp}/c_chat{i}.json")
choices = [one(f"{tmp}/c_one{i}.json") for i in (1, 2)]

end = lambda p: float(open(p).read()) - start
chat_ends = sorted(end(f"{tmp}/c_chat{i}.json.end") for i in (1, 2))
one_ends = sorted(end(f"{tmp}/c_one{i}.json.end") for i in (1, 2))

# decisions were fired 1.0s after the chats but must finish first
assert max(one_ends) < min(chat_ends), (
    f"decisions did not finish before chats: decisions end at {one_ends}, chats end at {chat_ends}")

print(f"e2e-concurrent: PASS 4/4 valid (decisions: {choices})")
print(f"  timeline: chats fired at 0.0s (end {chat_ends[0]:.1f}s/{chat_ends[1]:.1f}s), "
      f"decisions fired at 1.0s, done at {one_ends[0]:.1f}s/{one_ends[1]:.1f}s")
PY
