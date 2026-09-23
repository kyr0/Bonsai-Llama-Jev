#!/usr/bin/env bash
# Standard OpenAI-compatible endpoint checks against the running llama-server:
# GET /v1/models, POST /v1/chat/completions (non-streaming and streaming), plus
# the shared multimodal checks (media.sh) when the server advertises vision.
# Why: proves the ordinary chat surface still behaves after the systemone port.
set -euo pipefail
PORT="${PORT:-54100}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${API_KEY}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "e2e-openai: server not running on :${PORT} — start it with: make start" >&2
  exit 1
fi

echo "e2e-openai: GET /v1/models"
curl -sf -m 10 -H "$AUTH" "$BASE/v1/models" | python3 -c '
import json, sys
models = json.load(sys.stdin)
assert models["object"] == "list"
assert models["data"] and models["data"][0]["id"] and models["data"][0]["object"] == "model"
assert any(m["name"] == "jev-latest" for m in models["models"]), "TypeSafe alias missing"
print("e2e-openai: models PASS")
'

echo "e2e-openai: POST /v1/chat/completions (non-streaming)"
curl -sf -m 120 -X POST "$BASE/v1/chat/completions" -H "$AUTH" -H "Content-Type: application/json" -d @- <<'JSON' | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["object"] == "chat.completion" and r["id"].startswith("chatcmpl-"), r.get("id")
choice = r["choices"][0]
assert choice["message"]["role"] == "assistant"
assert isinstance(choice["message"]["content"], str)
assert choice["message"]["content"].strip(), "empty content"
assert choice["finish_reason"] in ("stop", "length"), choice["finish_reason"]
assert r["usage"]["prompt_tokens"] > 0 and r["usage"]["completion_tokens"] > 0
print("e2e-openai: chat PASS (" + r["choices"][0]["message"]["content"].strip()[:40].replace("\n", " ") + ")")
'
{
  "messages": [{"role": "user", "content": "Reply with exactly the word OK and nothing else."}],
  "max_tokens": 512,
  "chat_template_kwargs": {"enable_thinking": false}
}
JSON

echo "e2e-openai: POST /v1/chat/completions (streaming)"
curl -sN -m 120 -X POST "$BASE/v1/chat/completions" -H "$AUTH" -H "Content-Type: application/json" -d @- <<'JSON' | python3 -c '
import sys
saw_chunk = False
saw_done = False
text = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("data: "):
        continue
    payload = line[len("data: "):]
    if payload == "[DONE]":
        saw_done = True
        break
    import json
    chunk = json.loads(payload)
    assert chunk["object"] == "chat.completion.chunk", chunk.get("object")
    delta = chunk["choices"][0]["delta"] if chunk["choices"] else {}
    if isinstance(delta.get("content"), str):
        text.append(delta["content"])
    saw_chunk = True
assert saw_chunk, "no SSE chunks received"
assert saw_done, "stream not terminated with [DONE]"
assert "".join(text).strip(), "empty streamed content"
print("e2e-openai: streaming PASS")
'
{
  "messages": [{"role": "user", "content": "Reply with exactly the word OK and nothing else."}],
  "max_tokens": 512,
  "stream": true,
  "chat_template_kwargs": {"enable_thinking": false}
}
JSON

# Multimodal checks (shared with the jev suite): chat image_url + systemone media state.
bash "$SCRIPT_DIR/media.sh"
