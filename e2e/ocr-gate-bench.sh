#!/usr/bin/env bash
# OCR-gate bench against the running server: decide whether an image contains
# document-like text worth OCRing (multiple lines of meaningful text, not a
# single word or a few characters). Measures both paths on the same synthetic
# labeled image set (output/bench-ocr-gate/images, doc_* = positive, neg_* =
# negative):
#   1. /v1/systemone noul readout with the image as media state (no generation)
#   2. /v1/chat/completions with the image, answering strict JSON
#   3. full OCR reference on the positive images (image -> Markdown generation)
# Prints accuracy + confusion + images/s per gate path and per-document OCR
# cost. Hypothesis: the noul gate is much cheaper than running OCR (or even a
# chat answer) on every image.
# Skips (green) when the server has no vision projector, like media.sh.
set -euo pipefail
PORT="${PORT:-54100}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${API_KEY}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
BENCH_DIR="${BENCH_DIR:-$ROOT/output/bench-ocr-gate}"

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "bench-ocr-gate: server not running on :${PORT} - start it with: make start" >&2
  exit 1
fi

if ! curl -sf -m 5 -H "$AUTH" "$BASE/props" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["modalities"]["vision"] else 1)'; then
  echo "bench-ocr-gate: SKIPPED (server has no image support; start with BONSAI_MMPROJ)"
  exit 0
fi

MODEL=$(curl -sf -m 5 -H "$AUTH" "$BASE/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])')

echo "bench-ocr-gate: $BENCH_DIR (model=$MODEL)"
PORT="$PORT" API_KEY="$API_KEY" MODEL="$MODEL" ROOT="$ROOT" BENCH_DIR="$BENCH_DIR" python3 <<'PY'
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

port, key = os.environ["PORT"], os.environ["API_KEY"]
base, model = "http://127.0.0.1:" + port, os.environ["MODEL"]
root, bench_dir = os.environ["ROOT"], os.environ["BENCH_DIR"]
img_dir = os.path.join(bench_dir, "images")

# --- dataset: render real bench documents as positives, synthetic negatives ---
def generate():
    os.makedirs(img_dir, exist_ok=True)
    ner_dir = os.path.join(root, "bench_input", "ner")
    docs = sorted(f for f in os.listdir(ner_dir) if f.endswith(".json"))[:20]
    for i, name in enumerate(docs, 1):
        d = json.load(open(os.path.join(ner_dir, name)))
        text = d["invoice_part1"] + "\n\n" + d["sub"]["invoice_part2"]
        subprocess.run(["convert", "-size", "760x", "-background", "white", "-fill", "black",
                        "-font", "DejaVu-Sans", "-pointsize", "20", "label:" + text,
                        "-bordercolor", "white", "-border", "40",
                        os.path.join(img_dir, "doc_%02d.png" % i)], check=True)
    neg = 0
    def save(args, stem):
        nonlocal neg
        neg += 1
        subprocess.run(["convert"] + args + [os.path.join(img_dir, "%s_%d.png" % (stem, neg))],
                       check=True)
    for size in ("800x600", "640x480", "1000x700"):            # blank pages
        save(["-size", size, "xc:white"], "neg_blank")
    for word in ("OK", "Stop", "2026", "ID: 7"):               # single word / few chars
        save(["-size", "800x300", "xc:white", "-fill", "black", "-font", "DejaVu-Sans-Bold",
              "-pointsize", "64", "-gravity", "center", "-annotate", "0", word], "neg_word")
    for _ in range(4):                                          # photo-like plasma
        save(["-size", "800x600", "-seed", str(neg), "plasma:fractal"], "neg_plasma")
    save(["-size", "800x600", "gradient:blue-red"], "neg_gradient")
    save(["-size", "800x600", "gradient:yellow-green", "-rotate", "90"], "neg_gradient")
    save(["-size", "800x600", "xc:gray70", "+noise", "Gaussian"], "neg_noise")
    save(["-size", "800x600", "xc:gray30", "+noise", "Random", "-channel", "R", "-separate"],
         "neg_noise")
    for _ in range(3):                                          # geometric shapes
        save(["-size", "800x600", "xc:white", "-fill", "tomato", "-stroke", "black",
              "-draw", "rectangle 100,100 400,300", "-fill", "steelblue",
              "-draw", "circle 550,300 550,380"], "neg_shapes")

if not os.path.isdir(img_dir) or not os.listdir(img_dir):
    generate()
images = sorted(os.listdir(img_dir))
assert images, "no images in " + img_dir

def post(path, body, timeout):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit("bench-ocr-gate: POST %s failed: %d %s" % (path, e.code, e.read().decode()[:300]))

GATE = ("The image contains document-like text worth extracting with OCR: multiple lines of "
        "meaningful text such as a letter, invoice, form or report - not merely a single word, "
        "a few characters, shapes or a photo")
CHAT_PROMPT = ("Does this image contain document-like text worth extracting with OCR? "
               "Document-like means multiple lines of meaningful text (letter, invoice, form, "
               "report), not a single word, a few characters, shapes or a photo. "
               'Answer with JSON only: {"needs_ocr": true} or {"needs_ocr": false}')

def gate_systemone(name, b64):
    r = post("/v1/systemone", {"model": model, "state": {"image": name, "content": [
        {"type": "text", "text": "Image provided as evidence."},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}]},
        "questions": {"needs_ocr": {"type": "noul", "instructions": GATE}}}, 180)
    return r["answers"]["needs_ocr"]["noul"] >= 0.5, r["usage"]["input_tokens"]

def gate_chat(name, b64):
    r = post("/v1/chat/completions", {"model": model, "messages": [{"role": "user", "content": [
        {"type": "text", "text": CHAT_PROMPT},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}]}],
        "temperature": 0, "max_tokens": 64,
        "chat_template_kwargs": {"enable_thinking": False}}, 180)
    text = r["choices"][0]["message"]["content"]
    usage = r.get("usage", {})
    blob = text[text.find("{"):text.rfind("}") + 1]
    try:
        return bool(json.loads(blob)["needs_ocr"]), usage.get("completion_tokens", 0)
    except (ValueError, KeyError):
        return None, usage.get("completion_tokens", 0)  # unparseable JSON counts as wrong

def run(label, fn):
    conf = {"tp": 0, "fp": 0, "tn": 0, "fn": 0}
    tokens, parse_errors = 0, 0
    t0 = time.time()
    for name in images:
        b64 = base64.b64encode(open(os.path.join(img_dir, name), "rb").read()).decode()
        pred, used = fn(name, b64)
        tokens += used
        truth = name.startswith("doc_")
        if pred is None:
            parse_errors += 1
            conf["fn" if truth else "fp"] += 1  # unparseable JSON counts as wrong
        elif pred == truth:
            conf["tp" if pred else "tn"] += 1
        else:
            conf["fp" if pred else "fn"] += 1
        print("ocr-gate %-9s %s truth=%s pred=%s" % (label, name, truth, pred))
    elapsed = time.time() - t0
    acc = (conf["tp"] + conf["tn"]) / len(images)
    print("%s: accuracy=%.4f tp=%d fp=%d tn=%d fn=%d images=%d elapsed=%.1fs images/s=%.2f tokens=%d parse_errors=%d"
          % (label, acc, conf["tp"], conf["fp"], conf["tn"], conf["fn"],
             len(images), elapsed, len(images) / elapsed, tokens, parse_errors))
    return {"label": label, "accuracy": round(acc, 4), **conf, "elapsed_s": round(elapsed, 1),
            "images_per_s": round(len(images) / elapsed, 2), "tokens": tokens,
            "parse_errors": parse_errors}

results = [run("systemone", gate_systemone), run("chat", gate_chat)]

# full OCR reference: transcribe every positive document image to Markdown
OCR_PROMPT = ("Transcribe this document into Markdown. Keep every name, number, address "
              "and identifier exactly as printed.")  # same prompt as e2e/pii.sh
docs = [name for name in images if name.startswith("doc_")]
ocr_tokens, t0 = 0, time.time()
for name in docs:
    b64 = base64.b64encode(open(os.path.join(img_dir, name), "rb").read()).decode()
    start = time.time()
    r = post("/v1/chat/completions", {"model": model, "messages": [{"role": "user", "content": [
        {"type": "text", "text": OCR_PROMPT},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}]}],
        "temperature": 0, "max_tokens": 1024,
        "chat_template_kwargs": {"enable_thinking": False}}, 300)
    out = r["choices"][0]["message"]["content"]
    ocr_tokens += r.get("usage", {}).get("completion_tokens", 0)
    print("ocr-gate ocr       %s %.1fs (%d chars out)" % (name, time.time() - start, len(out)))
ocr_elapsed = time.time() - t0
ocr = {"label": "ocr", "images": len(docs), "elapsed_s": round(ocr_elapsed, 1),
       "s_per_doc": round(ocr_elapsed / len(docs), 2),
       "images_per_s": round(len(docs) / ocr_elapsed, 2), "tokens": ocr_tokens}
print("ocr: %d docs in %.1fs -> %.2fs/doc (%.2f docs/s, %d generated tokens)"
      % (len(docs), ocr_elapsed, ocr["s_per_doc"], ocr["images_per_s"], ocr_tokens))
results.append(ocr)

with open(os.path.join(bench_dir, "results.json"), "w") as f:
    json.dump(results, f, indent=2)
s, c = results[0], results[1]
print("verdict: systemone %.1fx faster than chat (%.2f vs %.2f images/s), accuracy %.4f vs %.4f"
      % (s["images_per_s"] / c["images_per_s"], s["images_per_s"], c["images_per_s"],
         s["accuracy"], c["accuracy"]))
print("verdict: gating with systemone costs %.2fs/image vs %.2fs/doc full OCR - %.1fx saved on rejected images"
      % (1 / s["images_per_s"], ocr["s_per_doc"], ocr["s_per_doc"] * s["images_per_s"]))
PY
