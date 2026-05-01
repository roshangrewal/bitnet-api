"""BitNet Inference API Gateway with persistent model process."""

import os, time, asyncio, glob, secrets, subprocess, threading, queue
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import jwt
from fastapi import FastAPI, HTTPException, Depends, Request
from fastapi.responses import JSONResponse, HTMLResponse, FileResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
MODELS_DIR = os.getenv("MODELS_DIR", "models")
CLI_PATH = os.getenv("CLI_PATH", "build/bin/llama-cli")
THREADS = os.getenv("THREADS", "4")
API_KEYS = set(os.getenv("API_KEYS", "sk-local-bitnet-key").split(",")) - {""}
JWT_SECRET = os.getenv("JWT_SECRET", secrets.token_hex(32))
JWT_EXPIRY_HOURS = int(os.getenv("JWT_EXPIRY_HOURS", "3"))
MAX_CONCURRENT = int(os.getenv("MAX_CONCURRENT", "2"))
RATE_LIMIT_RPM = int(os.getenv("RATE_LIMIT_RPM", "30"))
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "120"))

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
semaphore: asyncio.Semaphore
rate_limits: dict[str, list[float]] = {}
security = HTTPBearer(auto_error=False)


def discover_models() -> dict[str, str]:
    found = {}
    for gguf in glob.glob(f"{MODELS_DIR}/**/ggml-model-i2_s.gguf", recursive=True):
        found[Path(gguf).parent.name] = gguf
    return found


@asynccontextmanager
async def lifespan(app: FastAPI):
    global semaphore
    semaphore = asyncio.Semaphore(MAX_CONCURRENT)
    yield


app = FastAPI(title="BitNet Inference API", version="1.0.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# JWT
# ---------------------------------------------------------------------------
def create_jwt(api_key: str) -> dict:
    now = datetime.now(timezone.utc)
    exp = now + timedelta(hours=JWT_EXPIRY_HOURS)
    token = jwt.encode({"sub": api_key, "iat": now, "exp": exp}, JWT_SECRET, algorithm="HS256")
    return {"token": token, "expires_at": exp.isoformat(), "expires_in_seconds": JWT_EXPIRY_HOURS * 3600}


def verify_token(creds: HTTPAuthorizationCredentials = Depends(security)) -> str:
    if creds is None:
        raise HTTPException(status_code=401, detail="Missing Authorization header. Use: Bearer <jwt_token>")
    token = creds.credentials
    if token in API_KEYS:
        return token
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired. Generate a new one via POST /v1/auth/token")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")
    sub = payload.get("sub", "unknown")
    now = time.time()
    window = rate_limits.setdefault(sub, [])
    rate_limits[sub] = window = [t for t in window if now - t < 60]
    if len(window) >= RATE_LIMIT_RPM:
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    window.append(now)
    return sub


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
class Message(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    messages: list[Message]
    model: str = ""
    max_tokens: int = Field(default=512, le=4096)
    temperature: float = Field(default=0.7, ge=0, le=2)
    top_p: float = Field(default=0.9, ge=0, le=1)
    top_k: int = Field(default=40, ge=0)
    min_p: float = Field(default=0.1, ge=0, le=1)
    repeat_penalty: float = Field(default=1.0, ge=0)
    presence_penalty: float = Field(default=0.0, ge=0, le=2)
    frequency_penalty: float = Field(default=0.0, ge=0, le=2)

class AuthRequest(BaseModel):
    api_key: str


# ---------------------------------------------------------------------------
# Inference — per-request CLI (model loads each time but reliable)
# ---------------------------------------------------------------------------
async def run_inference(model_path: str, prompt: str, req: ChatRequest) -> str:
    cmd = [
        CLI_PATH, "-m", model_path, "-p", prompt,
        "-n", str(req.max_tokens), "-t", THREADS,
        "-ngl", "0", "-b", "1", "--no-warmup",
        "--temp", str(req.temperature),
        "--top-p", str(req.top_p),
        "--top-k", str(req.top_k),
        "--min-p", str(req.min_p),
        "--repeat-penalty", str(req.repeat_penalty),
        "--presence-penalty", str(req.presence_penalty),
        "--frequency-penalty", str(req.frequency_penalty),
    ]
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=REQUEST_TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        raise HTTPException(status_code=504, detail="Inference timed out")

    output = stdout.decode()
    resp = output.split("<|assistant|>")[-1] if "<|assistant|>" in output else output
    for stop in ["<|user|>", "<|endoftext|>", "<|system|>", "</|", "llama_perf", "\nuser\n", "[end of text]"]:
        if stop in resp:
            resp = resp[:resp.index(stop)]
    return resp.strip()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
async def chat_ui():
    return FileResponse("server/chat.html")


@app.get("/health")
async def health():
    return {"status": "ok", "models": list(discover_models().keys()), "queue_available": semaphore._value}


@app.get("/v1/models")
async def list_models():
    models = discover_models()
    return {"data": [{"id": name, "object": "model", "owned_by": "bitnet"} for name in sorted(models.keys())]}


@app.post("/v1/auth/token")
async def generate_token(req: AuthRequest):
    if req.api_key not in API_KEYS:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return create_jwt(req.api_key)


@app.get("/v1/docs", response_class=HTMLResponse)
async def api_docs():
    return FileResponse("server/api-docs.html")


@app.post("/v1/chat/completions")
async def chat_completions(req: ChatRequest, caller: str = Depends(verify_token)):
    models = discover_models()
    if not models:
        raise HTTPException(status_code=500, detail="No models found")

    model_path = models.get(req.model, list(models.values())[-1])
    prompt = "".join(f"<|{m.role}|>\n{m.content}\n" for m in req.messages) + "<|assistant|>\n"

    if semaphore._value == 0:
        raise HTTPException(status_code=503, detail="Server busy")

    async with semaphore:
        start = time.time()
        content = await run_inference(model_path, prompt, req)
        elapsed = time.time() - start

    return JSONResponse(content={
        "id": f"chatcmpl-{int(time.time())}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": req.model or list(models.keys())[-1],
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0, "elapsed_ms": int(elapsed * 1000)},
    })
