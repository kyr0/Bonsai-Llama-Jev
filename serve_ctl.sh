#!/usr/bin/env bash
# start|status|stop for llama-server. Never blocks: start detaches into a log
# file, status is one curl with a timeout, stop is one kill.
# Env: LLAMA_PORT (default 5382), LLAMA_HOST (default 0.0.0.0),
#      MODEL (required, path to a .gguf), LLAMA_ARGS (extra flags, e.g. "-ngl 99").
set -euo pipefail
cd "$(dirname "$0")"
PIDFILE=output/llama-serve.pid
LOG="${LLAMA_SERVE_LOG:-output/llama-serve.log}"
PORT="${LLAMA_PORT:-5382}"
HOST="${LLAMA_HOST:-0.0.0.0}"
SERVER="build/bin/llama-server"

alive() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-status}" in
  start)
    if alive; then
      echo "already running (pid $(cat "$PIDFILE")) -> http://${HOST}:${PORT}/health"
      exit 0
    fi
    if [ ! -x "$SERVER" ]; then
      echo "no server binary at $SERVER — build it first: make build" >&2
      exit 1
    fi
    if [ -z "${MODEL:-}" ] || [ ! -f "$MODEL" ]; then
      echo "MODEL missing or not a file: '${MODEL:-}'" >&2
      echo "usage: make start MODEL=/path/to/model.gguf" >&2
      exit 1
    fi
    mkdir -p output
    # shellcheck disable=SC2086 # LLAMA_ARGS is intentionally word-split extra flags
    "$SERVER" -m "$MODEL" --host "$HOST" --port "$PORT" ${LLAMA_ARGS:-} \
      >> "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    echo "starting pid $(cat "$PIDFILE") (model=$MODEL, ${HOST}:${PORT}), log: $LOG"
    echo "poll readiness with: make status"
    ;;
  status)
    if alive; then
      echo "pid $(cat "$PIDFILE") alive; health:"
      curl -s -m 3 "http://127.0.0.1:${PORT}/health" || echo "(still warming up — model load)"
    else
      echo "not running"
      exit 1
    fi
    ;;
  stop)
    if alive; then
      kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE" && echo "stopped pid $PIDFILE"
    else
      echo "not running"
      rm -f "$PIDFILE"
    fi
    ;;
  *)
    echo "usage: $0 start|status|stop" >&2
    exit 2
    ;;
esac
