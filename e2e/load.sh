#!/usr/bin/env bash
# Why: load probe for /v1/systemone - long states, long instructions, wide
# fan-out, N concurrent workers. Reproduces the eval timeout failure mode
# (slot starvation on small -np) and checks an over-long prompt fails with a
# named 422 instead of hanging. Usage: bash e2e/load.sh [workers]
set -euo pipefail
PORT="${PORT:-54100}"
API_KEY="${BONSAI_API_KEY:-local-dev-key}"
BASE="http://127.0.0.1:${PORT}"
WORKERS="${1:-20}"

if ! curl -sf -m 5 "$BASE/health" >/dev/null; then
  echo "load: server not running on :${PORT} - start it with: make start" >&2
  exit 1
fi

WORKERS="$WORKERS" BASE="$BASE" API_KEY="$API_KEY" python3 <<'PY'
import json, os, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

base, key = os.environ["BASE"], os.environ["API_KEY"]
workers = int(os.environ["WORKERS"])

def state(n_lines):
    # deterministic long support ticket: timestamped event log + narrative
    lines = [
        "2026-04-%02d %02d:%02dZ account=%d invoice=%d %s" % (
            (i % 28) + 1, i % 24, (i * 7) % 60, 40000 + i, 910000 + i * 13,
            "payment_failed reason=card_declined retry=%d amount_due=%d.%02d" % (i % 5, 400 + i, i)
            if i % 3 == 0 else
            "webhook_timeout endpoint=https://hooks.example.dev/billing attempt=%d latency_ms=%d" % (i % 4, 2000 + i * 17))
        for i in range(n_lines)
    ]
    header = ("Ticket #7741: nightly reconciliation keeps failing for our enterprise org. "
              "Three days of debugging, Stripe payouts stuck, our CFO is escalating today. "
              "Full event log and my notes follow.\n")
    return header + "\n".join(lines)

LONG_INSTR = ("Read the whole ticket and the event log carefully, weigh the account, invoice and "
              "webhook evidence, then pick the team that should own this: payments faults go to "
              "billing, API or integration faults to technical, contract and pricing questions to "
              "sales, and anything the evidence cannot place to review. ")

payload = {
    "model": "jev-latest",
    "state": {"ticket": state(200)},  # ~9k tokens: dates/numbers inflate ~45 tok/line
    "questions": {
        "department": {"type": "choice", "instructions": LONG_INSTR,
                       "criteria": {"billing": "Payment or subscription issues",
                                    "technical": "Bugs or integration problems",
                                    "sales": "Pricing or account questions",
                                    "review": "Needs a human to look first"}},
        "frustration": {"type": "score",
                        "instructions": "How frustrated is the author, judged from the tone of the "
                                        "ticket text and the retry counts in the log; use the full "
                                        "0-4 scale, do not hedge in the middle.",
                        "criteria": ["calm", "mildly annoyed", "clearly frustrated", "angry", "furious"]},
        "is_urgent": {"type": "noul",
                      "instructions": "The customer signals time pressure: sales loss, SLA risk or "
                                      "an escalation threat anywhere in the ticket"},
    },
}

def post(body):
    req = urllib.request.Request(
        base + "/v1/systemone", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return r.status, json.loads(r.read()), time.monotonic() - t0
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read()), time.monotonic() - t0
    except Exception as e:  # client timeout / conn reset -> a measured failure, not a crash
        return "ERR", {"error": str(e)[:120]}, time.monotonic() - t0

# 10 readouts per request: 4 choice labels + 5 score levels + 1 noul
print(f"load: {workers} concurrent systemone requests, ~9k-token state, long instructions, 10 readouts each")
with ThreadPoolExecutor(max_workers=workers) as pool:
    results = list(pool.map(lambda _: post(payload), range(workers)))

ok = [r for r in results if r[0] == 200]
for status, body, _ in results:
    if status != 200:
        print("load: FAIL example error:", json.dumps(body)[:200])
assert len(ok) == workers, f"only {len(ok)}/{workers} succeeded"
for _, r, _ in ok:
    a = r["answers"]
    assert a["department"]["choice"] in ("billing", "technical", "sales", "review")
    assert abs(sum(a["department"]["probabilities"].values()) - 1) < 1e-6
    assert 0.0 <= a["frustration"]["score"] <= 4.0
    assert 0.0 <= a["is_urgent"]["noul"] <= 1.0
lat = sorted(r[2] for r in ok)
print(f"load: {len(ok)}/{workers} OK  p50={lat[len(lat) // 2]:.2f}s p95={lat[int(len(lat) * 0.95)]:.2f}s max={lat[-1]:.2f}s")
print(f"load: input tokens per request = {ok[0][1]['usage']['input_tokens']}")

# over-long state must fail fast with a named 422, not hang or 500
status, body, dt = post({**payload, "state": {"ticket": state(4000)}})
assert status == 422 and "context" in json.dumps(body), (status, json.dumps(body)[:160])
print(f"load: oversize state -> clean 422 naming slot context ({dt:.2f}s)")
PY
