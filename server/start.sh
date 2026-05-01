#!/usr/bin/env bash
set -e

API_PORT="${API_PORT:-8000}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

export MODEL_PATH="${MODEL_PATH:-models/Falcon3-7B-Instruct-1.58bit/ggml-model-i2_s.gguf}"
export CLI_PATH="${CLI_PATH:-build/bin/llama-cli}"
export THREADS="${THREADS:-4}"

# Pre-cache all model files into page cache for fast loading
echo "=== Pre-caching models ==="
for f in models/*/ggml-model-i2_s.gguf; do
  echo "  Caching: $(basename $(dirname $f)) ($(du -h $f | cut -f1))"
  cat "$f" > /dev/null
done

echo "=== BitNet API ==="
echo "  Port:   $API_PORT"
if [ -n "$API_KEYS" ]; then
  echo "  Auth:   Custom keys"
else
  echo "  Auth:   Default key (sk-local-bitnet-key)"
fi
echo "  Chat:   http://0.0.0.0:$API_PORT"
echo "  Docs:   http://0.0.0.0:$API_PORT/v1/docs"
echo ""

uvicorn server.app:app --host 0.0.0.0 --port "$API_PORT"
