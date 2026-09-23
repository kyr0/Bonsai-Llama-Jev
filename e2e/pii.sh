#!/usr/bin/env bash
# Typed-decision PII pipeline against the running server:
#   1. OCR the invoice fixture into Markdown (vision chat, greedy)
#   2. /v1/systemone choice: is the document an invoice or a letter
#   3. scan the Markdown in 20-word slices: one choice per slice, every word
#      an option (plus "none"), to find PII words
#   4. one choice per found word for its PII type
#   5. print the type -> word mapping
# Skips (green) when the server has no vision projector, like media.sh.
set -euo pipefail
PORT="${PORT:-54100}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${API_KEY}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/openai-fixtures/ocr_invoice.png"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "e2e-pii: server not running on :${PORT} - start it with: make start" >&2
  exit 1
fi

if ! curl -sf -m 5 -H "$AUTH" "$BASE/props" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["modalities"]["vision"] else 1)'; then
  echo "e2e-pii: SKIPPED (server has no image support; start with BONSAI_MMPROJ)"
  exit 0
fi

MODEL=$(curl -sf -m 5 -H "$AUTH" "$BASE/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])')

echo "e2e-pii: OCR $(basename "$FIXTURE") -> Markdown, then typed PII decisions (model=$MODEL)"
PORT="$PORT" API_KEY="$API_KEY" MODEL="$MODEL" FIXTURE="$FIXTURE" TMP="$TMP" python3 <<'PY'
import base64, json, os, sys, time, urllib.error, urllib.request

port, key = os.environ["PORT"], os.environ["API_KEY"]
base, model = "http://127.0.0.1:" + port, os.environ["MODEL"]

def post(path, body, timeout):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit("e2e-pii: POST %s failed: %d %s" % (path, e.code, e.read().decode()[:300]))

t0 = time.time()
n_decisions = 0

def decide(state, name, instructions, criteria):
    global n_decisions
    n_decisions += 1
    return post("/v1/systemone", {"model": model, "state": state,
        "questions": {name: {"type": "choice", "instructions": instructions, "criteria": criteria}}}
    , 120)["answers"][name]

# 1) OCR the document into Markdown
img = base64.b64encode(open(os.environ["FIXTURE"], "rb").read()).decode()
ocr = post("/v1/chat/completions", {
    "model": model,
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": "Transcribe this document into Markdown. Keep every name, number, address and identifier exactly as printed."},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + img}},
    ]}],
    "temperature": 0,
    "max_tokens": 800,
    "chat_template_kwargs": {"enable_thinking": False},
}, 300)
md = ocr["choices"][0]["message"]["content"]
assert isinstance(md, str) and len(md.split()) >= 40, "OCR output too short: " + str(md)[:120]
open(os.environ["TMP"] + "/ocr.md", "w").write(md)
print("pii-ocr: PASS (%d words) %s..." % (len(md.split()), " ".join(md.split()[:8])))

# 2) invoice or letter?
doc = decide(md[:2000], "doc_type", "What kind of document is the evidence?",
             {"invoice": "a bill requesting payment for goods or services",
              "letter": "correspondence without a payment request"})
assert doc["choice"] == "invoice", doc
print("pii-doc: PASS invoice (confidence %.2f)" % doc["confidence"])

# 3) scan 20-word slices: every word is an option, pick the PII one; repeat
# with the picked word removed until the model picks none
CHUNK = 20
words = md.split()
found = []  # (word, confidence), in document order
SCAN_INSTRUCTIONS = ("Pick the one word that is personal or identifying information "
                     "(part of a name, company, address, email, phone, customer number, date, IBAN or BIC). "
                     "If none qualifies, pick none.")
for i in range(0, len(words), CHUNK):
    slice_ = words[i:i + CHUNK]
    remaining = list(dict.fromkeys(slice_))
    while remaining:
        criteria = {w: "is this a PII information or not" for w in remaining}
        criteria["none"] = "no remaining word in this list is personal or identifying information"
        a = decide(" ".join(slice_), "pii_word", SCAN_INSTRUCTIONS, criteria)
        if a["choice"] == "none":
            break
        found.append((a["choice"], a["confidence"]))
        print("pii-scan: chunk %d/%d -> %s (p=%.2f)" % (i // CHUNK + 1, -(-len(words) // CHUNK), a["choice"], a["confidence"]))
        remaining.remove(a["choice"])
assert found, "no PII word found in any chunk"

# 4) classify each found word
TYPES = {
    "firstname": "a person's given or first name",
    "lastname":  "a person's family or last name",
    "company":   "a company or organization name",
    "address":   "a street address, postal code or city",
    "email":     "an email address",
    "phone":     "a phone or fax number",
    "customer_number": "a customer, order or invoice reference number",
    "date":      "a calendar date",
    "iban":      "an IBAN bank account number",
    "bic":       "a BIC or SWIFT bank identifier code",
    "vat_id":    "a VAT tax registration identifier",
    "amount":    "a monetary amount",
    "other":     "none of the listed types",
}
labeled = {}
for word, conf in found:
    context = "\n".join(l for l in md.splitlines() if word in l)[:1500]
    a = decide(context, "pii_type",
               "Classify the word '%s' from the evidence. What kind of personal or identifying information is it?" % word,
               TYPES)
    labeled[word] = a["choice"]

# 5) print the mapping, grouped by type
by_type = {}
for word, typ in labeled.items():
    by_type.setdefault(typ, []).append(word)
print("pii-map: " + ", ".join("%s: %s" % (t, ", ".join(ws)) for t, ws in sorted(by_type.items())))

types = set(by_type)
assert len(labeled) >= 4, "expected at least 4 PII words, got %s" % list(labeled)
assert types & {"iban", "bic", "vat_id"}, "no banking identifier found in %s" % sorted(types)
assert "date" in types, "no date found in %s" % sorted(types)
assert types & {"firstname", "lastname", "company"}, "no name-like PII found in %s" % sorted(types)
print("e2e-pii: PASS (%d PII words, %d types, %d decisions in %.1fs)"
      % (len(labeled), len(types), n_decisions, time.time() - t0))
PY
