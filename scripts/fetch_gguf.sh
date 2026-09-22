#!/bin/sh
# Download GGUF files from any Hugging Face model repo into models/<repo-name>/
# and print the command to run them with the demo.
#
# Usage:
#   ./scripts/fetch_gguf.sh <repo_id>                      list the repo's GGUF files
#   ./scripts/fetch_gguf.sh <repo_id> <file|pattern ...>   download the named files
#
#   repo_id   e.g. prism-ml/Bonsai-27B-GGUF (any model repo, public or private)
#   file      exact file name in the repo, e.g. model-PQ2_0.gguf
#   pattern   glob with '*', e.g. '*PQ2_0*' or '*mmproj*' (quote it)
#
# Options (before the repo id):
#   --dest DIR   destination directory (default: models/<last part of repo_id>)
#   --token TOK  Hugging Face token; or set HF_TOKEN. Required for private repos.
#   --revision R branch, tag or commit (default: main)
#
# Needs the hf CLI (pip install -U huggingface_hub) and curl.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

dest=""; token="${HF_TOKEN:-}"; revision="main"
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) dest="$2"; shift 2 ;;
        --token) token="$2"; shift 2 ;;
        --revision) revision="$2"; shift 2 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*) echo "[ERR] unknown option $1" >&2; exit 1 ;;
        *) break ;;
    esac
done

repo="${1:-}"
[ -n "$repo" ] || { echo "usage: $0 [--dest DIR] [--token TOK] [--revision R] <repo_id> [file|pattern ...]" >&2; exit 1; }
case "$repo" in */*) ;; *) echo "[ERR] repo id must look like owner/name (got '$repo')" >&2; exit 1 ;; esac
shift

command -v hf >/dev/null 2>&1 || { echo "[ERR] hf CLI not found (pip install -U huggingface_hub)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[ERR] curl not found" >&2; exit 1; }

auth=""
[ -n "$token" ] && auth="Authorization: Bearer $token"

# List the repo's GGUF files (name and size) through the Hub API.
listing="$(curl -sf ${auth:+-H "$auth"} "https://huggingface.co/api/models/$repo/tree/$revision" 2>/dev/null || true)"
if [ -z "$listing" ]; then
    echo "[ERR] cannot read $repo (revision $revision). Private repo? Pass --token or set HF_TOKEN." >&2
    exit 1
fi
files="$(printf '%s' "$listing" | tr -d '\n' | sed 's/},{/}\
{/g' | grep '\.gguf"' | while IFS= read -r obj; do
        path="$(printf '%s' "$obj" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')"
        size="$(printf '%s' "$obj" | sed -n 's/.*"size":\([0-9]*\).*/\1/p')"
        [ -n "$path" ] && printf '%s %s\n' "${size:-0}" "$path"
    done | sort -k2)"
[ -n "$files" ] || { echo "[ERR] no .gguf files in $repo" >&2; exit 1; }

if [ $# -eq 0 ]; then
    echo "GGUF files in $repo:"
    printf '%s\n' "$files" | awk '{ printf "  %8.2f GiB  %s\n", $1/1024/1024/1024, $2 }'
    echo ""
    echo "Download with:  ${HF_TOKEN:+HF_TOKEN=... }$0 $repo <file|pattern ...>"
    exit 0
fi

[ -n "$dest" ] || dest="$DEMO_DIR/models/$(basename "$repo")"
mkdir -p "$dest"

# Exact names are passed as-is; anything with '*' becomes an --include pattern.
names=""; includes=""
for arg in "$@"; do
    case "$arg" in
        *\**) matched=0
              for f in $(printf '%s\n' "$files" | awk '{print $2}'); do case "$f" in $arg) matched=1 ;; esac; done
              [ $matched -eq 1 ] || { echo "[ERR] pattern '$arg' matches no .gguf in $repo" >&2; exit 1; }
              includes="$includes --include $arg" ;;
        *) printf '%s\n' "$files" | awk '{print $2}' | grep -qx "$arg" || { echo "[ERR] $arg is not in $repo" >&2; exit 1; }
           names="$names $arg" ;;
    esac
done

echo "==> downloading from $repo into $dest"
# shellcheck disable=SC2086
hf download "$repo" $names $includes --revision "$revision" --local-dir "$dest" ${token:+--token "$token"} >/dev/null

echo ""
echo "GGUF files in $dest:"
ls -lh "$dest"/*.gguf 2>/dev/null | awk '{ printf "  %6s  %s\n", $5, $NF }'

# Pick a model file and a projector for the launch line: prefer what was just
# named, otherwise the first non-projector GGUF present.
model=""; mmproj=""
for n in $names; do case "$n" in *mmproj*) ;; *.gguf) [ -f "$dest/$n" ] && model="$dest/$n" ;; esac; done
if [ -z "$model" ]; then
    for f in "$dest"/*.gguf; do case "$f" in *mmproj*) ;; *) [ -f "$f" ] && model="$f" && break ;; esac; done
fi
for f in "$dest"/*mmproj*.gguf; do [ -f "$f" ] && mmproj="$f" && break; done

rel() { case "$1" in "$DEMO_DIR"/*) printf '%s' "${1#"$DEMO_DIR"/}" ;; *) printf '%s' "$1" ;; esac; }
echo ""
if [ -z "$model" ]; then
    echo "No model weights in $dest yet (only a projector). Download one first, e.g.:"
    echo "  $0 $repo '*PQ2_0*'"
    exit 0
fi
echo "Run with the demo:"
if [ -n "$mmproj" ]; then
    echo "  BONSAI_GGUF=$(rel "$model") BONSAI_MMPROJ=$(rel "$mmproj") ./scripts/start_llama_server.sh"
else
    echo "  BONSAI_GGUF=$(rel "$model") ./scripts/start_llama_server.sh"
fi