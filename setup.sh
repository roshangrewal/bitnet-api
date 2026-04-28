#!/usr/bin/env bash
# ============================================================
# BitNet API — One-Command Setup
# ============================================================
# Usage:
#   bash setup.sh                    # Falcon3-7B (default)
#   bash setup.sh 3b                 # Falcon3-3B (faster)
#   bash setup.sh 10b                # Falcon3-10B (best, needs 60GB disk)
# ============================================================
set -e

MODEL_SIZE="${1:-7b}"
case "$MODEL_SIZE" in
  1b)  REPO="tiiuae/Falcon3-1B-Instruct-1.58bit" ;;
  3b)  REPO="tiiuae/Falcon3-3B-Instruct-1.58bit" ;;
  7b)  REPO="tiiuae/Falcon3-7B-Instruct-1.58bit" ;;
  10b) REPO="tiiuae/Falcon3-10B-Instruct-1.58bit" ;;
  *)   echo "Usage: bash setup.sh [3b|7b|10b]"; exit 1 ;;
esac

MODEL_NAME=$(basename "$REPO")

# --- Resource requirements per model ---
case "$MODEL_SIZE" in
  1b)  DISK_SETUP="5GB"  DISK_FINAL="0.8GB" RAM_MIN="2GB" ;;
  3b)  DISK_SETUP="15GB" DISK_FINAL="2.1GB" RAM_MIN="4GB" ;;
  7b)  DISK_SETUP="35GB" DISK_FINAL="3.1GB" RAM_MIN="8GB" ;;
  10b) DISK_SETUP="60GB" DISK_FINAL="4.5GB" RAM_MIN="12GB" ;;
esac

echo ""
echo "  ⚡ BitNet API Setup"
echo "  Model: $MODEL_NAME"
echo ""
echo "  Requirements:"
echo "    Disk (during setup): ~$DISK_SETUP (temp, auto-cleaned)"
echo "    Disk (final):        ~$DISK_FINAL"
echo "    RAM:                 $RAM_MIN minimum"
echo ""

# --- Check prerequisites ---
MISSING=0
check() {
  if command -v "$1" &>/dev/null; then
    echo "  ✅ $1 found"
  else
    echo "  ❌ $1 missing — $2"
    MISSING=1
  fi
}

echo "  Checking prerequisites..."
check git "Install: brew install git (macOS) / apt install git (Linux)"
check conda "Install: https://docs.conda.io/en/latest/miniconda.html"

# Init submodules if not already done
if [ ! -f "3rdparty/llama.cpp/CMakeLists.txt" ]; then
  echo "  >>> Initializing submodules..."
  git submodule update --init --recursive
fi

# Check clang (needed for compilation)
if command -v clang &>/dev/null; then
  echo "  ✅ clang found"
else
  echo "  ❌ clang missing — Install: xcode-select --install (macOS) / apt install clang (Linux)"
  MISSING=1
fi

# Check disk space
FREE_GB=$(df -g . 2>/dev/null | tail -1 | awk '{print $4}' || df -BG . 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
if [ -n "$FREE_GB" ]; then
  echo "  📁 Free disk: ${FREE_GB}GB"
fi

echo ""

if [ "$MISSING" -eq 1 ]; then
  echo "  ❌ Install missing prerequisites above and re-run."
  exit 1
fi

# --- Conda env ---
if ! conda env list 2>/dev/null | grep -q "bitnet-cpp"; then
  echo ">>> Creating conda environment..."
  conda create -n bitnet-cpp python=3.9 -y -q
fi

eval "$(conda shell.bash hook)"
conda activate bitnet-cpp

# Install cmake if missing
command -v cmake &>/dev/null || { echo ">>> Installing cmake..."; conda install cmake -y -q; }

# --- Dependencies ---
echo ">>> Installing dependencies..."
pip install -q -r requirements.txt
pip install -q -r server/requirements.txt

# --- Build & download model ---
GGUF="models/$MODEL_NAME/ggml-model-i2_s.gguf"
if [ -f "$GGUF" ]; then
  echo ">>> Model already exists: $GGUF"
else
  echo ">>> Downloading & building $MODEL_NAME (this takes 5-15 min)..."
  python setup_env.py --hf-repo "$REPO" -q i2_s 2>&1 | grep -E "INFO|ERROR"

  # Clean up temp files
  echo ">>> Cleaning up temp files..."
  rm -f "models/$MODEL_NAME/ggml-model-f32.gguf"
  find "models/$MODEL_NAME" -name "*.safetensors" -delete 2>/dev/null
  find "models/$MODEL_NAME" -name "*.bin" -delete 2>/dev/null
fi

echo ""
echo "  ✅ Setup complete!"
echo ""
echo "  Run the API:"
echo "    conda activate bitnet-cpp"
echo "    ./server/start.sh"
echo ""
echo "  Then open:"
echo "    Chat UI:  http://localhost:8000"
echo "    API Docs: http://localhost:8000/v1/docs"
echo ""
echo "  To enable auth (for public/cloud hosting):"
echo "    API_KEYS=sk-your-key ./server/start.sh"
echo ""
