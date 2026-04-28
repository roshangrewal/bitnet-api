#!/usr/bin/env bash
# ============================================================
# BitNet Cloud Setup — Falcon3-10B-Instruct-1.58bit
# ============================================================
# Run on a fresh Ubuntu 22.04+ VM:
#   curl -sL https://raw.githubusercontent.com/YOUR_REPO/main/server/cloud-setup.sh | bash
#
# Requirements:
#   - Ubuntu 22.04+
#   - 8+ vCPU, 16GB+ RAM
#   - 60GB+ free disk (for conversion temp files)
#   - Recommended: Standard_D8as_v5 (Azure), c6a.2xlarge (AWS)
# ============================================================
set -e

MODEL_REPO="${MODEL_REPO:-tiiuae/Falcon3-10B-Instruct-1.58bit}"
MODEL_NAME=$(basename "$MODEL_REPO")
QUANT="${QUANT:-i2_s}"
API_KEYS="${API_KEYS:-YOUR_API_KEY}"
API_PORT="${API_PORT:-8000}"
THREADS="${THREADS:-$(nproc)}"

PROJECT_DIR="$HOME/bitnet"

echo "============================================================"
echo " BitNet Cloud Setup"
echo " Model: $MODEL_REPO"
echo " Threads: $THREADS"
echo "============================================================"
echo ""

# --- 1. System dependencies ---
echo ">>> [1/6] Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential git cmake clang python3 python3-pip python3-venv nginx certbot python3-certbot-nginx > /dev/null 2>&1
echo "    Done."

# --- 2. Clone repo ---
echo ">>> [2/6] Cloning BitNet..."
if [ -d "$PROJECT_DIR" ]; then
    echo "    Already exists, pulling latest..."
    cd "$PROJECT_DIR" && git pull --quiet
else
    git clone --recursive --quiet https://github.com/microsoft/BitNet.git "$PROJECT_DIR"
fi
cd "$PROJECT_DIR"

# --- 3. Python env ---
echo ">>> [3/6] Setting up Python environment..."
python3 -m venv .venv
source .venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt
pip install -q fastapi uvicorn httpx pydantic
echo "    Done."

# --- 4. Download & build model ---
echo ">>> [4/6] Downloading and building model (this takes 10-20 min)..."
python setup_env.py --hf-repo "$MODEL_REPO" -q "$QUANT" 2>&1 | grep -E "INFO|ERROR|error"
echo "    Done."

# Clean up temp files (f32 intermediate can be 40GB+)
echo ">>> Cleaning up intermediate files..."
rm -f "models/$MODEL_NAME/ggml-model-f32.gguf"
find "models/$MODEL_NAME" -name "*.safetensors" -delete 2>/dev/null
find "models/$MODEL_NAME" -name "*.bin" -delete 2>/dev/null
echo "    Freed disk space."

# --- 5. Install server ---
echo ">>> [5/6] Setting up API server..."
mkdir -p server

cat > server/app.py << 'APPEOF'
import os, time, asyncio, json
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Depends
from fastapi.responses import JSONResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field

MODEL_PATH = os.getenv("MODEL_PATH", "")
CLI_PATH = os.getenv("CLI_PATH", "build/bin/llama-cli")
THREADS = os.getenv("THREADS", "4")
API_KEYS = set(os.getenv("API_KEYS", "YOUR_API_KEY").split(","))
MAX_CONCURRENT = int(os.getenv("MAX_CONCURRENT", "2"))
RATE_LIMIT_RPM = int(os.getenv("RATE_LIMIT_RPM", "30"))
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "180"))

semaphore: asyncio.Semaphore
rate_limits: dict[str, list[float]] = {}
security = HTTPBearer()

@asynccontextmanager
async def lifespan(app: FastAPI):
    global semaphore
    semaphore = asyncio.Semaphore(MAX_CONCURRENT)
    yield

app = FastAPI(title="BitNet Inference API", version="1.0.0", lifespan=lifespan)

def verify_key(creds: HTTPAuthorizationCredentials = Depends(security)) -> str:
    key = creds.credentials
    if key not in API_KEYS:
        raise HTTPException(status_code=401, detail="Invalid API key")
    now = time.time()
    window = rate_limits.setdefault(key, [])
    rate_limits[key] = window = [t for t in window if now - t < 60]
    if len(window) >= RATE_LIMIT_RPM:
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    window.append(now)
    return key

class Message(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    messages: list[Message]
    model: str = "falcon3-10b-instruct-1.58bit"
    max_tokens: int = Field(default=512, le=4096)
    temperature: float = Field(default=0.7, ge=0, le=2)

async def run_inference(prompt: str, max_tokens: int, temperature: float) -> str:
    cmd = [CLI_PATH, "-m", MODEL_PATH, "-p", prompt, "-n", str(max_tokens),
           "-t", THREADS, "-ngl", "0", "-b", "1", "--temp", str(temperature), "--no-warmup"]
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=REQUEST_TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        raise HTTPException(status_code=504, detail="Inference timed out")
    output = stdout.decode()
    resp = output.split("<|assistant|>")[-1] if "<|assistant|>" in output else output
    for stop in ["<|user|>", "<|endoftext|>", "<|system|>", "</|", "llama_perf", "\nuser\n"]:
        if stop in resp:
            resp = resp[:resp.index(stop)]
    return resp.strip()

@app.get("/health")
async def health():
    return {"status": "ok", "model": MODEL_PATH, "queue_available": semaphore._value}

@app.post("/v1/chat/completions")
async def chat_completions(req: ChatRequest, api_key: str = Depends(verify_key)):
    prompt = "".join(f"<|{m.role}|>\n{m.content}\n" for m in req.messages) + "<|assistant|>\n"
    if semaphore._value == 0:
        raise HTTPException(status_code=503, detail="Server busy")
    async with semaphore:
        start = time.time()
        content = await run_inference(prompt, req.max_tokens, req.temperature)
        elapsed = time.time() - start
    return JSONResponse(content={
        "id": f"chatcmpl-bitnet-{int(time.time())}",
        "object": "chat.completion",
        "model": req.model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "usage": {"elapsed_ms": int(elapsed * 1000)},
    })
APPEOF

echo "    Done."

# --- 6. Systemd service ---
echo ">>> [6/6] Creating systemd service..."
GGUF_PATH=$(find "$PROJECT_DIR/models/$MODEL_NAME" -name "ggml-model-i2_s.gguf" | head -1)

sudo tee /etc/systemd/system/bitnet.service > /dev/null << EOF
[Unit]
Description=BitNet Inference API
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR
Environment=MODEL_PATH=$GGUF_PATH
Environment=CLI_PATH=$PROJECT_DIR/build/bin/llama-cli
Environment=THREADS=$THREADS
Environment=API_KEYS=$API_KEYS
Environment=MAX_CONCURRENT=2
Environment=REQUEST_TIMEOUT=180
ExecStart=$PROJECT_DIR/.venv/bin/uvicorn server.app:app --host 127.0.0.1 --port $API_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Nginx
sudo tee /etc/nginx/sites-available/bitnet > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_read_timeout 180s;
        client_max_body_size 1m;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/bitnet /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

sudo systemctl daemon-reload
sudo systemctl enable --now bitnet

echo ""
echo "============================================================"
echo " ✅ BitNet API is live!"
echo ""
echo " API:     http://$(curl -s ifconfig.me 2>/dev/null || echo YOUR_IP):80"
echo " Health:  curl http://localhost/health"
echo " Model:   $MODEL_NAME ($QUANT)"
echo " GGUF:    $GGUF_PATH"
echo ""
echo " Test:"
echo "   curl -X POST http://localhost/v1/chat/completions \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -H 'Authorization: Bearer $API_KEYS' \\"
echo "     -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'"
echo ""
echo " Add HTTPS:"
echo "   sudo certbot --nginx -d yourdomain.com"
echo ""
echo " Logs:"
echo "   sudo journalctl -u bitnet -f"
echo "============================================================"
