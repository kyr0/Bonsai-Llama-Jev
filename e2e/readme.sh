#!/usr/bin/env bash
# Replays the worked examples from README.md verbatim against the running
# llama-server and asserts the response shape the README documents.
# Why: the README is the first thing a new user copy-pastes; if the server
# surface drifts, the examples must fail here before they fail for them.
set -euo pipefail
PORT="${PORT:-54100}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${API_KEY}"

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "e2e-readme: server not running on :${PORT} — start it with: make start" >&2
  exit 1
fi

# README "First message": the answer is in the JSON under
# choices[0].message.content.
echo "e2e-readme: README 'First message' (POST /v1/chat/completions)"
curl -sf -m 120 -X POST "$BASE/v1/chat/completions" -H "$AUTH" -H "Content-Type: application/json" -d @- <<'JSON' | python3 -c '
import json, sys
r = json.load(sys.stdin)
content = r["choices"][0]["message"]["content"]
assert isinstance(content, str) and content.strip(), "README: answer must be in choices[0].message.content"
print("e2e-readme: first-message PASS (" + content.strip()[:40].replace("\n", " ") + ")")
'
{
  "messages": [{"role": "user", "content": "Hello!"}],
  "max_tokens": 200
}
JSON

# README "Typed questions": department is a choice over the criteria, noul is a
# yes/no confidence from 0 to 1, and score is the weighted average of the
# scale levels.
echo "e2e-readme: README 'Typed questions' (POST /v1/systemone)"
curl -sf -m 120 -X POST "$BASE/v1/systemone" -H "$AUTH" -H "Content-Type: application/json" -d @- <<'JSON' | python3 -c '
import json, sys
r = json.load(sys.stdin)
a = r["answers"]
assert set(a) == {"department", "urgency", "frustration"}, a.keys()
dept = a["department"]
assert dept["choice"] in ("billing", "technical"), dept
assert abs(sum(dept["probabilities"].values()) - 1.0) < 1e-6, dept
noul = a["urgency"]["noul"]
assert 0.0 <= noul <= 1.0, noul
fr = a["frustration"]
assert set(fr["probabilities"]) == {"0", "1", "2"}, fr
expected = sum(int(k) * v for k, v in fr["probabilities"].items())
assert abs(fr["score"] - expected) < 1e-3, (fr["score"], expected)
print("e2e-readme: typed-questions PASS " + json.dumps(a))
'
{
  "model": "bonsai-2-27b",
  "state": "My payouts have failed for three days, please help today.",
  "questions": {
    "department":  {"type": "choice", "instructions": "Which team handles this?",
                    "criteria": {"billing": "Payments", "technical": "Bugs"}},
    "urgency":     {"type": "noul",   "instructions": "The message is time-sensitive"},
    "frustration": {"type": "score",  "instructions": "How frustrated?",
                    "criteria": ["Calm", "Frustrated", "Furious"]}
  }
}
JSON

echo "e2e-readme: ALL README EXAMPLES PASS"
