#!/usr/bin/env bash
set -e

API_PORT="${API_PORT:-8000}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

export MODEL_PATH="${MODEL_PATH:-models/Falcon3-7B-Instruct-1.58bit/ggml-model-i2_s.gguf}"
export CLI_PATH="${CLI_PATH:-build/bin/llama-cli}"
export THREADS="${THREADS:-4}"

echo "=== BitNet API ==="
echo "  Model:  $MODEL_PATH"
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
