#!/usr/bin/env bash
# Build PrismML llama.cpp (llama-server + llama-cli) from this checkout.
# Why: pins nothing by default - this tree carries the typed-decisions work, so
# we build it in place; fetching/checking out a tag would detach the branch.
# Set LLAMA_DEST to build a pristine external clone at a pinned tag instead.
# Env: LLAMA_BACKEND (metal|cuda|vulkan|cpu), LLAMA_REPO, LLAMA_TAG, LLAMA_DEST.
set -euo pipefail

REPO="${LLAMA_REPO:-https://github.com/PrismML-Eng/llama.cpp}"
TAG="${LLAMA_TAG:-prism}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${LLAMA_DEST:-$HERE}"

# Pick the accelerator. Override with LLAMA_BACKEND=metal|cuda|vulkan|cpu.
if [ -n "${LLAMA_BACKEND:-}" ]; then
  BACKEND="$LLAMA_BACKEND"
elif [ "$(uname -s)" = "Darwin" ]; then
  BACKEND=metal
elif command -v nvcc >/dev/null 2>&1; then
  BACKEND=cuda
elif command -v vulkaninfo >/dev/null 2>&1; then
  BACKEND=vulkan
else
  BACKEND=cpu
fi

case "$BACKEND" in
  metal)  FLAGS=(-DGGML_METAL=ON) ;;
  cuda)   FLAGS=(-DGGML_CUDA=ON) ;;
  vulkan) FLAGS=(-DGGML_VULKAN=ON) ;;
  cpu)    FLAGS=() ;;
  *) echo "unknown LLAMA_BACKEND=$BACKEND" >&2; exit 1 ;;
esac

echo "building PrismML llama.cpp ($TAG, $BACKEND) into $DEST"

if [ "$DEST" = "$HERE" ]; then
  # In-place build of the current working tree; never fetch/checkout here.
  :
elif [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch --depth 1 origin "$TAG"
  git -C "$DEST" checkout -q FETCH_HEAD
else
  git clone --depth 1 --branch "$TAG" "$REPO" "$DEST"
fi

cmake -S "$DEST" -B "$DEST/build" -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF "${FLAGS[@]}"
cmake --build "$DEST/build" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)" \
      --target llama-server llama-cli

echo
echo "built: $DEST/build/bin/llama-server"
"$DEST/build/bin/llama-server" --version 2>&1 | head -2
