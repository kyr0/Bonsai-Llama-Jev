# 🌳🦙 Bonsai-Llama-Jev

**TL;DR:**
- Everything you know from llama.cpp/ollama + System One API support + image support.
- Everything you know from Qwen3.8-27B + image support but 9x smaller, much faster, and runs on a 12 GB-class GPU.
- Pareto-optimal (quality/resources/speed) drop-in replacement for Jev/SystemOne API AND OpenAI API running inside the **same service**, tested with the official TypeSafe SDKs (Python + JS).
- **98% of Qwen3.8-27B accuracy** | **99% of Jev accuracy**

## ✨ What it can do

- 💡 **It decides like Jev!** — send typed decisions requests via JSON (`/v1/systemone`, works with the official TypeSafe AI SDK!)

- 💬 **It can still chat** — send messages, get answers (`/v1/chat/completions`, works with any OpenAI client!)

- 🖼️ **It works with images!** — send a photo along with your question - **also** works with Jev-like requests!

- 🧠 **It still thinks, before it answers!** — it can still reason (in OpenAI API)

- 🛠️ **It can still use tools!** — can still call tools (in OpenAI API)

- 🔌 **It is a TRUE drop-in replacement for Jev!** — tested with the official `typesafe-sdk` (Python) and `@typesafe-ai/sdk` (JS) out of the box

- 🏠 **It runs ON YOUR COMPUTER AT HOME!** — no cloud, no internet, no data leaving your machine

- 🏎️ **It is REALLY FAST!** — 
  - SystemOne API ("Typed Decisions"): 
  - OpenAI API ("Chat"): 143 tokens/second on NVIDIA GeForce RTX 5090; 46.8 tokens/second on M5 Max

- 🧩 **Small!** — 10 GB GPU (VRAM) memory **including** KV cache; 9x smaller than Qwen3.8-27B; a 12 GB-class GPU is enough!

- 🏆 **It is REALLY GOOD!**
  - SystemOne API ("Typed Decisions"): 
  - OpenAI API ("Chat"): **98%** of the official Qwen3.8-27B performance on average on the same tasks [see benchmark](https://prismml.com/news/bonsai-2-27b)

## 🏗️ What it consumes

| | | |
| --- | --- | --- |
| 🎮 GPU memory | ~10 GB | weights 7 GB + image projector (mmproj) 0.6 GB + KV cache/compute (at 64k context window) ≈ 2.3 GB |
| 💽 Disk | ~20 GB | model files ~17 GB (you only need 3 of the 4 GGUFs), code + build ~1.6 GB |

A 12 GB graphics card is enough. Run it on CPU without a GPU too, just slowly.

## But is it actually GOOD?



## And is it really FAST?



## 🚀 Run it

You need: a Linux or Mac machine, an NVIDIA GPU (recommended), about 20 GB of free disk.

**Step 1 — install everything** (builds the server, downloads the model):

```sh
make setup
```

**Step 2 — start it:**

```sh
make start
```

That's it. The server runs in the background at `http://localhost:8080`.
`make start` also runs a few self-checks and prints PASS for each one.

## 🗨️ First message

```sh
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 200}'
```

The answer is in the JSON under `choices[0].message.content`. With the OpenAI SDK, just point it
at the server (key only needed if you set `BONSAI_API_KEY`):

```python
# pip install openai
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="local-dev-key")
r = client.chat.completions.create(
    model="local-model",  # any name works unless you set BONSAI_ALIAS
    messages=[{"role": "user", "content": "Hello!"}],
)
print(r.choices[0].message.content)
```

Same for `@openai/openai` / any other OpenAI-compatible client — set the base URL and it works.

## 🧠 Typed questions (`POST /v1/systemone`)

Ask many questions at once and get numbers back:

```sh
curl http://localhost:8080/v1/systemone -H "Content-Type: application/json" -d '{
  "model": "local-model",
  "state": "My payouts have failed for three days, please help today.",
  "questions": {
    "department":  {"type": "choice", "instructions": "Which team handles this?",
                    "criteria": {"billing": "Payments", "technical": "Bugs"}},
    "urgency":     {"type": "noul",   "instructions": "The message is time-sensitive"},
    "frustration": {"type": "score",  "instructions": "How frustrated?",
                    "criteria": ["Calm", "Frustrated", "Furious"]}
  }
}'
```

Answer:

```json
{"answers": {
  "department":  {"choice": "technical", "probabilities": {"billing": 0.07, "technical": 0.93}},
  "urgency":     {"noul": 0.99},
  "frustration": {"score": 1.01, "probabilities": {"0": 0.01, "1": 0.96, "2": 0.03}}
}}
```

`noul` is a yes/no confidence from 0 to 1. `score` is the weighted average of the scale levels.
The model never "writes" these numbers — they come straight from what it would say next.
Details: [tools/server/SYSTEMONE.md](tools/server/SYSTEMONE.md).

## 🖼️ Send an image

Same chat endpoint — put an image into the message:

```json
{"role": "user", "content": [
  {"type": "text", "text": "What is in this picture?"},
  {"type": "image_url", "image_url": {"url": "data:image/png;base64,...."}}
]}
```

Works for `/v1/systemone` too — the state becomes an object with a `content` array instead of a
plain string (checked end to end by `make e2e-jev`):

```sh
curl http://localhost:8080/v1/systemone -H "Content-Type: application/json" -d '{
  "model": "local-model",
  "state": {
    "ticket": "color-check",
    "content": [
      {"type": "text", "text": "What color is the square?"},
      {"type": "image_url", "image_url": {"url": "data:image/png;base64,...."}}
    ]
  },
  "questions": {
    "is_red": {"type": "noul", "instructions": "The dominant shape in the image is red"},
    "color":  {"type": "choice", "instructions": "Primary color of the shape",
               "criteria": {"red": "red", "blue": "blue", "green": "green"}}
  }
}'
```

```json
{"answers": {
  "is_red": {"noul": 0.98},
  "color":  {"choice": "red", "probabilities": {"red": 0.97, "blue": 0.02, "green": 0.01}}
}}
```

Image tokens count toward `usage.input_tokens` like any other input.

## 🔌 From code (SDKs)

The typed endpoint speaks the TypeSafe wire format, so the official SDKs work as-is:

```python
# pip install typesafe-sdk
from typesafe_sdk import Choice, Noul, TypeSafeClient

with TypeSafeClient(base_url="http://localhost:8080") as client:  # + api_key if you set one
    r = client.system_one(
        state="My payouts have failed for three days, please help today.",
        questions={
            "department": Choice(instructions="Which team?", criteria={"billing": "Payments", "technical": "Bugs"}),
            "urgency": Noul(instructions="The message is time-sensitive"),
        },
    )
print(r.choices["department"].choice, r.nouls["urgency"].noul)  # technical 0.99
```

```js
// npm i @typesafe-ai/sdk
import { TypeSafeClient, choice } from "@typesafe-ai/sdk";

const client = new TypeSafeClient({ baseURL: "http://localhost:8080" });
const r = await client.systemOne({
  state: "I was charged twice. Please fix this ASAP.",
  questions: { tone: choice("Customer tone?", { calm: null, angry: null }) },
});
console.log(r.answers.tone.choice);
```

Both are checked on every `make e2e` run, so "drop-in" is verified, not promised.

## 🎛️ Commands

| Command | What it does |
| --- | --- |
| `make setup` | Install + build + download the model (first time only) |
| `make start` | Start the server in the background, run the self-checks once |
| `make stop` | Stop it |
| `make status` | Is it alive — which model is loaded, plus both endpoint URLs (`/v1/chat/completions`, `/v1/systemone`) |
| `make logs` | Watch the server log (Ctrl-C to stop watching) |
| `make e2e` | Full self-check: OpenAI chat, streaming, images, both SDKs |
| `make e2e-openai` / `make e2e-jev` | Just one part of the checks |
| `make configure-h200` | Pick your GPU (also `-rtx-pro-6000-ada`, `-rtx-5050`, `-rtx-3090`, or plain `-cuda`), then `make build` |
| `make llama-server ARGS="..."` | Run the server binary yourself with your own flags |

## ⚙️ Settings

Copy `.env.example` to `.env`, then edit. The ones you might need:

- `PORT` — which port (default 8080)
- `BONSAI_API_KEY` — require this password; empty = no password
- `BONSAI_ALIAS` — model name shown in `/v1/models`
- `BONSAI_MAX_TOKENS` — hard ceiling on generated tokens per request
- `BONSAI_CTX` — context size (0 = auto)
- `BONSAI_NGL` — GPU layers: `99` = everything (default), `0` = CPU only
- `BONSAI_GGUF` — serve a different GGUF file instead
- `BONSAI_MMPROJ` — image projector that belongs to it
- `CUDA_VISIBLE_DEVICES` — which GPU, e.g. `1`

## ❓ Something wrong?

- Server not answering? → `make status`, then `make logs`
- Out of GPU memory? → put `BONSAI_NGL=40` in `.env` (fewer layers on the GPU) and `make stop && make start`
- Want a different model? → set `BONSAI_GGUF=/path/to/model.gguf` in `.env`

MIT license. The underlying engine is [llama.cpp](https://github.com/ggml-org/llama.cpp);
its [docs folder](docs/) has everything else.
