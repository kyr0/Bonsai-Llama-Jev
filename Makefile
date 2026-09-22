SHELL := /bin/bash
# Optional .env (see .env.example) configures PORT, BONSAI_HOST, BONSAI_API_KEY,
# BONSAI_ALIAS, ... — the scripts load it too (scripts/common.sh).
-include .env
PORT ?= 8080
BONSAI_HOST ?= 127.0.0.1
BUILD_DIR ?= build
CUDA_PATH ?= /usr/local/cuda
NPROC ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)
CONFIGURE_STAMP := $(BUILD_DIR)/.configure-args
# Extra llama-server flags via LLAMA_ARGS (e.g. LLAMA_ARGS="-ngl 99"),
# a custom GGUF via BONSAI_GGUF, and HF cache/credentials through to the server.
# BONSAI_MAX_TOKENS caps generation server-wide (--n-predict).
export PORT BONSAI_HOST BONSAI_API_KEY BONSAI_ALIAS BONSAI_GGUF BONSAI_MAX_TOKENS BONSAI_NP BONSAI_CALIBRATION HF_HOME HF_TOKEN
.PHONY: setup build configure configure-cuda configure-h200 configure-rtx-pro-6000-ada configure-rtx-5050 configure-rtx-3090 llama llama-server start logs status stop e2e-openai e2e-jev e2e vram

# One-command setup: deps, venv, build (skipped if build/bin/llama-server exists),
# and the Bonsai-2-27B model download.
setup:
	@bash setup.sh

# Configure the build for a specific NVIDIA GPU (CUDA is the default backend;
# the chosen flags are persisted in build/.configure-args and reused by make build).
configure-cuda configure-h200 configure-rtx-pro-6000-ada configure-rtx-5050 configure-rtx-3090:
	@mkdir -p $(BUILD_DIR)
	@case "$@" in \
	  configure-h200)              arch=90 ;; \
	  configure-rtx-pro-6000-ada)  arch=89 ;; \
	  configure-rtx-5050)          arch=120 ;; \
	  configure-rtx-3090)          arch=86 ;; \
	  *)                           arch="" ;; \
	esac; \
	args="-DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DGGML_CUDA=ON"; \
	if [ -n "$$arch" ]; then args="$$args -DCMAKE_CUDA_ARCHITECTURES=$$arch"; fi; \
	printf '%s\n' "$$args" > $(CONFIGURE_STAMP); \
	echo "configure: cmake -S . -B $(BUILD_DIR) $$args"; \
	PATH="$(CUDA_PATH)/bin:$$PATH" cmake -S . -B $(BUILD_DIR) $$args

# Re-apply the persisted configuration after build/ was wiped.
configure:
	@if [ ! -f $(CONFIGURE_STAMP) ]; then \
	  echo "configure: nothing configured yet — defaulting to generic CUDA"; \
	  $(MAKE) configure-cuda; \
	else \
	  echo "configure: re-applying saved configuration: $$(cat $(CONFIGURE_STAMP))"; \
	  PATH="$(CUDA_PATH)/bin:$$PATH" cmake -S . -B $(BUILD_DIR) $$(cat $(CONFIGURE_STAMP)); \
	fi

# Build llama-server + llama-cli with the configuration last configured
# (falls back to a generic CUDA configure when nothing was configured yet).
build:
	@if [ ! -f $(BUILD_DIR)/CMakeCache.txt ]; then $(MAKE) configure; fi
	@PATH="$(CUDA_PATH)/bin:$$PATH" cmake --build $(BUILD_DIR) --target llama-server llama-cli -j$(NPROC)
	@echo "built: $(BUILD_DIR)/bin/llama-server"

# Raw passthrough to the built binaries with the runtime library path set;
# pass flags via ARGS="..." (see --help).
llama-server:
	@LD_LIBRARY_PATH=$(BUILD_DIR)/bin:$${LD_LIBRARY_PATH:-} $(BUILD_DIR)/bin/llama-server $(ARGS)

llama:
	@LD_LIBRARY_PATH=$(BUILD_DIR)/bin:$${LD_LIBRARY_PATH:-} $(BUILD_DIR)/bin/llama-cli $(ARGS)

# Start the server in the background with the configured Bonsai model, wait
# until the log shows "llama_server: listening on", then run the e2e suites
# once as a warmup. Runtime artifacts live in output/ (gitignored).
start:
	@mkdir -p output
	@nohup bash scripts/start_llama_server.sh $(LLAMA_ARGS) > output/llama-serve.log 2>&1 & \
	pid=$$!; echo $$pid > output/llama-serve.pid; \
	for i in $$(seq 1 120); do \
	  grep -q "llama_server: listening on" output/llama-serve.log 2>/dev/null && break; \
	  kill -0 $$pid 2>/dev/null || { echo "start: server died early — last log lines:" >&2; tail -n 3 output/llama-serve.log >&2; exit 1; }; \
	  sleep 1; \
	done; \
	if ! grep -q "llama_server: listening on" output/llama-serve.log 2>/dev/null; then \
	  echo "start: timeout waiting for listen — see output/llama-serve.log" >&2; exit 1; \
	fi; \
	echo "start: server listening on :$(PORT) (pid $$pid) — running e2e warmup"; \
	$(MAKE) --no-print-directory e2e

# Is it alive — model, calibration, default hyperparams per endpoint, URLs.
# Chat sampling defaults come from /props (server truth); System One is a pure
# logits readout (no sampling), its only knob is the calibration temperature.
status:
	@health=$$(curl -s -m 3 "http://$(BONSAI_HOST):$(PORT)/health" || true); \
	case "$$health" in \
	  *ok*) echo "alive: http://$(BONSAI_HOST):$(PORT)  (health: $$health)"; \
	        model=$$(curl -s -m 3 -H "Authorization: Bearer $(BONSAI_API_KEY)" "http://$(BONSAI_HOST):$(PORT)/v1/models" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("models") or d.get("data") or [{}])[0].get("name") or "unknown")' 2>/dev/null || echo "(unknown)"); \
	        echo "  model: $$model"; \
	        pid=$$(lsof -ti TCP:$(PORT) | head -1); \
	        calib=$$(ps -p $$pid -o command= 2>/dev/null | sed -n 's/.*--systemone-calibration \([^ ]*\).*/\1/p'); \
	        ct=$$(CALIB="$$calib" python3 -c 'import json,os; d=json.load(open(os.environ["CALIB"])); per=d.get("temperatures") or {}; print(" ".join(["T=%g"%d["temperature"]]+["%s=%g"%(k,v) for k,v in sorted(per.items())]))' 2>/dev/null || true); \
	        if [ -n "$$calib" ]; then echo "  calib: on  ($$ct, $$calib)"; else echo "  calib: off"; fi; \
	        hyper=$$(curl -s -m 3 -H "Authorization: Bearer $(BONSAI_API_KEY)" "http://$(BONSAI_HOST):$(PORT)/props" | python3 -c 'import json,sys; p=json.load(sys.stdin).get("default_generation_settings",{}).get("params",{}); print("temp %g, top_p %g, top_k %g"%(p.get("temperature"),p.get("top_p"),p.get("top_k")))' 2>/dev/null || echo "(unavailable)"); \
	        echo "  chat:  http://$(BONSAI_HOST):$(PORT)/v1/chat/completions  ($$hyper)"; \
	        echo "  typed: http://$(BONSAI_HOST):$(PORT)/v1/systemone  (greedy logits, no sampling)" ;; \
	  *)    echo "(not running or still warming up on :$(PORT))" ;; \
	esac

# Follow the background server log (Ctrl-C to stop watching).
logs:
	@touch output/llama-serve.log
	@tail -n 50 -f output/llama-serve.log

stop:
	@kill $$(lsof -ti TCP:$(PORT)) 2>/dev/null && echo "stopped port $(PORT)" || echo "not running"
	@rm -f output/llama-serve.pid

# Standard OpenAI-compatible endpoints (models, chat completions, streaming).
e2e-openai:
	@bash e2e/openai.sh

# Jev-like typed-decision query against the running server (/v1/systemone).
e2e-jev:
	@bash e2e/systemone.sh

# Full compatibility suite against the running server: OpenAI endpoints,
# documented cURL request, Python typesafe-sdk, JS @typesafe-ai/sdk.
e2e:
	@bash e2e/run.sh

PID_FILE := output/llama-serve.pid

vram:
	@if [[ ! -f $(PID_FILE) ]] || ! kill -0 "$$(cat $(PID_FILE))" 2>/dev/null; then \
		echo "not running"; exit 1; \
	fi; \
	pids="$$(cat $(PID_FILE))"; \
	while :; do \
		children=$$(pgrep -P "$$(echo $$pids | tr ' ' ',')" 2>/dev/null | tr '\n' ' '); \
		new=""; for c in $$children; do [[ " $$pids " == *" $$c "* ]] || new="$$new $$c"; done; \
		[[ -z "$$new" ]] && break; pids="$$pids$$new"; \
	done; \
	nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits | \
	awk -v pids="$$pids" -F', ' '{ split(pids, a, " "); for (i in a) if ($$1+0 == a[i]+0) s += $$2 } \
	END { if (s > 0) printf "VRAM used (incl. KV cache): %d MB\n", s; else { print "no GPU memory reported for server pid(s) " pids; exit 1 } }'
