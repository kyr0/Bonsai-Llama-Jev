#!/usr/bin/env bash
# NER bench against the running server (/v1/systemone typed decisions):
#   1. scan each bench_input/ner document in 20-word slices: one choice per
#      slice, every word an option (plus "none"), to find entity words
#   2. one choice per found word for its entity type (the bench_gold labels)
#   3. dedicated POSTAL_ADDRESS pass: split into sentences with a smart regex
#      (no split on dates, abbreviations or single newlines, so multi-line
#      address blocks stay whole), then per sentence a choice loop picks the
#      address words - a single word is never "a complete postal address", so
#      the generic classifier in step 2 can never emit this label
#   4. score entity-level against bench_gold/ner: a gold entity counts as found
#      when a predicted word of the same label lands inside its span
# Writes word-level predictions to output/bench-ner/ and prints per-label and
# micro precision/recall/F1. BENCH_LIMIT=N restricts to the first N documents.
set -euo pipefail
PORT="${PORT:-54100}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${API_KEY}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
INPUT_DIR="${BENCH_INPUT:-$ROOT/bench_input/ner}"
GOLD_DIR="${BENCH_GOLD:-$ROOT/bench_gold/ner}"
OUT_DIR="${BENCH_OUT:-$ROOT/output/bench-ner}"

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "bench-ner-accuracy: server not running on :${PORT} - start it with: make start" >&2
  exit 1
fi

MODEL=$(curl -sf -m 5 -H "$AUTH" "$BASE/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])')

mkdir -p "$OUT_DIR"
echo "bench-ner-accuracy: $INPUT_DIR vs $GOLD_DIR -> $OUT_DIR (model=$MODEL)"
PORT="$PORT" API_KEY="$API_KEY" MODEL="$MODEL" INPUT_DIR="$INPUT_DIR" GOLD_DIR="$GOLD_DIR" \
  OUT_DIR="$OUT_DIR" BENCH_LIMIT="${BENCH_LIMIT:-0}" python3 <<'PY'
import json, os, re, sys, time, urllib.error, urllib.request
from collections import Counter

port, key = os.environ["PORT"], os.environ["API_KEY"]
base, model = "http://127.0.0.1:" + port, os.environ["MODEL"]
input_dir, gold_dir, out_dir = (os.environ[k] for k in ("INPUT_DIR", "GOLD_DIR", "OUT_DIR"))
limit = int(os.environ.get("BENCH_LIMIT") or 0)

def post(path, body, timeout):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit("bench-ner-accuracy: POST %s failed: %d %s" % (path, e.code, e.read().decode()[:300]))

n_decisions = 0

def decide(state, name, instructions, criteria):
    global n_decisions
    n_decisions += 1
    return post("/v1/systemone", {"model": model, "state": state,
        "questions": {name: {"type": "choice", "instructions": instructions, "criteria": criteria}}}
    , 120)["answers"][name]

# the bench_gold/ner label set, plus an escape hatch
LABELS = {
    "COMPANY_NAME": "a company or organization name",
    "PERSON_NAME": "a person's name",
    "POSTAL_ADDRESS": "a complete postal address",
    "STREET_ADDRESS": "a street and house number",
    "POSTAL_CODE": "a postal code",
    "CITY": "a city name",
    "STATE_OR_REGION": "a state, region or province",
    "COUNTRY": "a country name",
    "ORDER_NUMBER": "an order or purchase-order number",
    "ACCOUNT_ID": "a customer or client account identifier",
    "TAX_ID": "a tax identifier such as USt-IdNr or Steuer-ID",
    "TAX_NUMBER": "a tax number (Steuernummer)",
    "DOCUMENT_DATE": "the document issue date",
    "SERVICE_DATE": "a service or performance date",
    "DATE": "a generic calendar date",
    "DELIVERY_DATE": "a delivery or shipping date",
    "INVOICE_NUMBER": "an invoice number",
    "INVOICE_DATE": "the invoice date",
    "DUE_DATE": "a payment due date",
    "TRANSACTION_DATE": "a payment transaction date",
    "other": "none of the listed entity types",
}

SCAN_INSTRUCTIONS = ("Pick the one word that is part of a named entity "
                     "(company, person, address, identifier or date). "
                     "If none qualifies, pick none.")
ADDRESS_INSTRUCTIONS = ("Pick the one word that belongs to a postal address "
                        "(street, house number, postal code, city, region or country part). "
                        "Exclude company names, person names and section headers. "
                        "If none qualifies, pick none.")
CHUNK = 20
FIELDS = ("invoice_part1", "sub.invoice_part2")

# sentence end candidates: punctuation followed by whitespace, or a blank line
_SENT_END = re.compile(r"[.!?]\s+|\n\s*\n")
# words whose trailing dot is not a sentence end (German abbreviations)
_ABBR_WORDS = {"z.b", "z", "b", "u.a", "u", "d.h", "nr", "ca", "bzw", "ggf", "dr",
               "fr", "hr", "vs", "etc", "zzgl", "incl", "evtl", "max", "min"}


def sentence_spans(text):
    """Smart sentence split with offsets.

    No split after dates/decimals (digit before the dot), known abbreviations or
    single-letter initials; single newlines never split, so multi-line address
    blocks stay one sentence. Blank lines always split.
    """
    spans, start = [], 0
    for m in _SENT_END.finditer(text):
        if m.group()[0] in ".!?":
            before = text[:m.start()].split()
            word = before[-1] if before else ""
            if word and (word[-1].isdigit() or word.lower() in _ABBR_WORDS
                         or re.fullmatch(r"[A-ZÄÖÜ]", word)):
                continue
        spans.append((start, m.start() + 1))
        start = m.end()
    if start < len(text):
        spans.append((start, len(text)))
    return [(s, e) for s, e in spans if text[s:e].split()]

def resolve(document, path):
    cur = document
    for part in path.split("."):
        cur = cur[part]
    assert isinstance(cur, str), path
    return cur

names = sorted(f for f in os.listdir(input_dir) if f.endswith(".json"))
if limit:
    names = names[:limit]
assert names, "no .json documents in " + input_dir

t0 = time.time()

# 1+2) find and classify entity words per document
for name in names:
    document = json.load(open(os.path.join(input_dir, name)))
    # join with a newline so the last word of part1 never glues to part2 headers
    text = "\n".join(resolve(document, f) for f in FIELDS)
    toks = [(m.group(), m.start(), m.end()) for m in re.finditer(r"\S+", text)]
    found = []  # global token indices picked as entity words
    for i in range(0, len(toks), CHUNK):
        slice_toks = toks[i:i + CHUNK]
        remaining = list(dict.fromkeys(w for w, _, _ in slice_toks))
        while remaining:
            criteria = {w: "is this word part of a named entity or not" for w in remaining}
            criteria["none"] = "no remaining word in this list is part of a named entity"
            a = decide(" ".join(w for w, _, _ in slice_toks), "entity_word", SCAN_INSTRUCTIONS, criteria)
            if a["choice"] == "none" or a["choice"] not in remaining:
                break
            for j, (w, _, _) in enumerate(slice_toks):
                if w == a["choice"] and (i + j) not in found:
                    found.append(i + j)
                    break
            remaining.remove(a["choice"])
    entities = []
    for idx in found:
        w, s, e = toks[idx]
        context = "\n".join(l for l in text.splitlines() if w in l)[:1500]
        a = decide(context, "entity_type",
                   "Classify the word '%s' from the evidence. What kind of entity is it part of?" % w,
                   LABELS)
        if a["choice"] != "other":
            entities.append({"label": a["choice"], "text": w, "start": s, "end": e})
    # POSTAL_ADDRESS pass: per sentence, pick the address words in one choice
    # loop; the sentence is the decision state, so every pick sees full context
    for s_start, s_end in sentence_spans(text):
        sentence = text[s_start:s_end]
        stoks = [(m.group(), s_start + m.start(), s_start + m.end())
                 for m in re.finditer(r"\S+", sentence)]
        if len(stoks) < 3:
            continue
        remaining = list(dict.fromkeys(w for w, _, _ in stoks))
        picked = set()
        while remaining:
            criteria = {w: "does this word belong to a postal address" for w in remaining}
            criteria["none"] = "no remaining word in this sentence belongs to a postal address"
            a = decide(sentence, "address_word", ADDRESS_INSTRUCTIONS, criteria)
            if a["choice"] == "none" or a["choice"] not in remaining:
                break
            for w, s, e in stoks:
                if w == a["choice"] and (s, e) not in picked:
                    picked.add((s, e))
                    break
            remaining.remove(a["choice"])
        for s, e in sorted(picked):
            entities.append({"label": "POSTAL_ADDRESS", "text": text[s:e], "start": s, "end": e})
    with open(os.path.join(out_dir, name), "w") as f:
        json.dump({"entities": entities}, f, ensure_ascii=False)
    print("ner-run: %s -> %d entity words" % (name, len(entities)))

# 3) entity-level scoring: word span inside gold span, same label
tp, fp, fn = Counter(), Counter(), Counter()
problems = []
for name in names:
    gold_path = os.path.join(gold_dir, name)
    if not os.path.isfile(gold_path):
        problems.append("%s: no gold file" % name)
        continue
    document = json.load(open(os.path.join(input_dir, name)))
    part1 = resolve(document, FIELDS[0])
    # +1 for the newline separator used when concatenating the fields
    bases = {FIELDS[0]: 0, FIELDS[1]: len(part1) + 1}
    gold = []
    for g in json.load(open(gold_path))["entities"]:
        field = g["source_path"].removeprefix("$.")
        if field not in bases or resolve(document, field)[g["start"]:g["end"]] != g["text"]:
            problems.append("%s: bad gold span %s" % (name, g.get("source_path")))
            continue
        gold.append((g["label"], bases[field] + g["start"], bases[field] + g["end"]))
    pred = [(p["label"], p["start"], p["end"])
            for p in json.load(open(os.path.join(out_dir, name)))["entities"]]
    for label in {g[0] for g in gold} | {p[0] for p in pred}:
        gspans = [g for g in gold if g[0] == label]
        pspans = [p for p in pred if p[0] == label]
        inside = lambda p: any(g[1] <= p[1] and p[2] <= g[2] for g in gspans)
        hits = sum(1 for g in gspans if any(g[1] <= p[1] and p[2] <= g[2] for p in pspans))
        tp[label] += hits
        fn[label] += len(gspans) - hits
        fp[label] += sum(1 for p in pspans if not inside(p))

def prf(t, f_p, f_n):
    p = t / (t + f_p) if t + f_p else 0.0
    r = t / (t + f_n) if t + f_n else 0.0
    return p, r, (2 * p * r / (p + r) if p + r else 0.0)

print("%-20s %6s %6s %6s %6s %6s %8s %8s %8s" % ("LABEL", "GOLD", "PRED", "TP", "FP", "FN", "P", "R", "F1"))
for label in sorted(tp.keys() | fp.keys() | fn.keys()):
    p, r, f1 = prf(tp[label], fp[label], fn[label])
    print("%-20s %6d %6d %6d %6d %6d %8.4f %8.4f %8.4f"
          % (label, tp[label] + fn[label], tp[label] + fp[label], tp[label], fp[label], fn[label], p, r, f1))
p, r, f1 = prf(sum(tp.values()), sum(fp.values()), sum(fn.values()))
print("%-20s %6d %6d %6d %6d %6d %8.4f %8.4f %8.4f"
      % ("MICRO", sum(tp.values()) + sum(fn.values()), sum(tp.values()) + sum(fp.values()),
         sum(tp.values()), sum(fp.values()), sum(fn.values()), p, r, f1))
for problem in problems:
    print("PROBLEM " + problem, file=sys.stderr)
print("micro_f1=%.4f problems=%d decisions=%d elapsed=%.1fs"
      % (f1, len(problems), n_decisions, time.time() - t0))
sys.exit(1 if problems else 0)
PY
