#!/usr/bin/env bash
# Shared multimodal checks for the openai and jev e2e suites: the red-square
# fixture through /v1/chat/completions (image_url part) and the /v1/systemone
# media-state extension. Skips (green) when the server has no vision projector,
# so text-only deployments stay unaffected.
set -euo pipefail
PORT="${PORT:-5382}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${API_KEY}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/openai-fixtures/test.png"

if ! curl -sf -m 5 -H "$AUTH" "$BASE/props" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["modalities"]["vision"] else 1)'; then
  echo "media: vision SKIPPED (server has no image support; start with BONSAI_MMPROJ)"
  exit 0
fi

# tr instead of base64 -w0: portable across GNU and BSD/macOS coreutils
IMG_B64=$(base64 < "$FIXTURE" | tr -d '\n')

echo "media: POST /v1/chat/completions (image fixture)"
curl -sf -m 180 -X POST "$BASE/v1/chat/completions" -H "$AUTH" -H "Content-Type: application/json" -d @- <<JSON | python3 -c '
import json, sys
r = json.load(sys.stdin)
text = r["choices"][0]["message"]["content"].lower()
assert "red" in text, "image content not understood: " + text[:80]
print("media: chat image PASS (" + text.strip()[:40].replace("\n", " ") + ")")
'
{
  "messages": [{"role": "user", "content": [
    {"type": "text", "text": "What color is the square in this image? Answer with a single word."},
    {"type": "image_url", "image_url": {"url": "data:image/png;base64,${IMG_B64}"}}
  ]}],
  "max_tokens": 512,
  "chat_template_kwargs": {"enable_thinking": false}
}
JSON

echo "media: POST /v1/systemone (media-state image fixture)"
curl -sf -m 180 -X POST "$BASE/v1/systemone" -H "$AUTH" -H "Content-Type: application/json" -d @- <<JSON | python3 -c '
import json, sys
r = json.load(sys.stdin)
if "error" in r:
    raise SystemExit("systemone media error: " + json.dumps(r["error"])[:200])
a = r["answers"]
noul = a["is_red"]["noul"]
choice = a["color"]["choice"]
assert 0.0 <= noul <= 1.0, noul
assert noul > 0.5, "model did not recognize the red square: noul=" + str(noul)
assert choice == "red", choice
assert r["usage"]["input_tokens"] > 0, "image tokens must count toward usage"
print("media: systemone vision PASS (noul=" + str(round(noul, 3)) + ", color=" + choice + ")")
'
{
  "model": "jev-latest",
  "state": {
    "ticket": "color-check",
    "content": [
      {"type": "text", "text": "What color is the square?"},
      {"type": "image_url", "image_url": {"url": "data:image/png;base64,${IMG_B64}"}}
    ]
  },
  "questions": {
    "is_red": {"type": "noul", "instructions": "The dominant shape in the image is red"},
    "color": {"type": "choice", "instructions": "Primary color of the shape", "criteria": {"red": "red", "blue": "blue", "green": "green"}}
  }
}
JSON
