SHELL := /bin/bash
# Optional .env (see .env.example) configures PORT, BONSAI_HOST, BONSAI_API_KEY,
# BONSAI_ALIAS, ... — the scripts load it too (scripts/common.sh).
-include .env
PORT ?= 8080
BONSAI_HOST ?= 127.0.0.1
# Extra llama-server flags via LLAMA_ARGS (e.g. LLAMA_ARGS="-ngl 99"),
# a custom GGUF via BONSAI_GGUF, and HF cache/credentials through to the server.
export PORT BONSAI_HOST BONSAI_API_KEY BONSAI_ALIAS BONSAI_GGUF HF_HOME HF_TOKEN
.PHONY: setup build start status stop e2e-jev e2e

# One-command setup: deps, venv, build (skipped if build/bin/llama-server exists),
# and the Bonsai-2-27B model download.
setup:
	@bash setup.sh

# Build llama-server + llama-cli (backend auto-detected; LLAMA_BACKEND=cpu make build
# to pin, LLAMA_DEST=... to build a pristine clone at LLAMA_TAG instead of this tree).
build:
	@bash build.sh

# Foreground server with the downloaded Bonsai model (Ctrl-C to stop).
start:
	@bash scripts/start_llama_server.sh $(LLAMA_ARGS)

status:
	@curl -s -m 3 "http://127.0.0.1:$(PORT)/health" || echo "(not running or still warming up)"

stop:
	@kill $$(lsof -ti TCP:$(PORT)) 2>/dev/null && echo "stopped port $(PORT)" || echo "not running"

# Jev-like typed-decision query against the running server (/v1/systemone).
e2e-jev:
	@bash e2e/jev.sh

# Full SDK compatibility suite against the running server:
# documented cURL request + Python typesafe-sdk + JS @typesafe-ai/sdk.
e2e:
	@bash e2e/run.sh
