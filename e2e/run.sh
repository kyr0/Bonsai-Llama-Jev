#!/usr/bin/env bash
# Runs the full TypeSafe SDK compatibility suite against the running
# llama-server: documented cURL request, Python typesafe-sdk, JS @typesafe-ai/sdk.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-5382}"
BASE="http://127.0.0.1:${PORT}"

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "e2e: server not running on :${PORT} — start it with: make start (or BONSAI_GGUF=/path/model.gguf make start)" >&2
  exit 1
fi

# the SDKs assert the response model name; ask the server what it serves
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
MODEL=$(curl -sf -m 5 -H "Authorization: Bearer ${API_KEY}" "$BASE/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])')
export TYPESAFE_BASE_URL="$BASE"
export TYPESAFE_EXPECTED_MODEL="$MODEL"
export TYPESAFE_API_KEY="$API_KEY"

echo "== cURL documented request =="
bash e2e/curl.sh

echo "== Python typesafe-sdk =="
if [ ! -x e2e/python/.venv/bin/python ]; then
  echo "e2e: e2e/python/.venv missing — create it with: uv venv e2e/python/.venv && uv pip install --python e2e/python/.venv 'typesafe-sdk==0.7.0'" >&2
  exit 1
fi
e2e/python/.venv/bin/python e2e/python/test_sdk.py

echo "== JavaScript @typesafe-ai/sdk =="
if [ ! -d e2e/js/node_modules ]; then
  echo "e2e: e2e/js/node_modules missing — install with: (cd e2e/js && npm ci)" >&2
  exit 1
fi
(cd e2e/js && node test-sdk.mjs)

echo "e2e: ALL SUITES PASS"
