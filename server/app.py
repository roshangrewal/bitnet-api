"""BitNet Inference API - routes to persistent llama-server backends."""

import os, time, asyncio, secrets, logging
from contextlib import asynccontextmanager

import httpx
import jwt
from fastapi import FastAPI, HTTPException, Depends, Request
from fastapi.responses import JSONResponse, HTMLResponse, FileResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
from datetime import datetime, timedelta, timezone

logger = logging.getLogger("bitnet")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

# Config
API_KEYS = set(os.getenv("API_KEYS", "sk-local-bitnet-key").split(",")) - {""}
JWT_SECRET = os.getenv("JWT_SECRET", secrets.token_hex(32))
JWT_EXPIRY_HOURS = int(os.getenv("JWT_EXPIRY_HOURS", "3"))
RATE_LIMIT_RPM = int(os.getenv("RATE_LIMIT_RPM", "30"))
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "300"))

BACKENDS = {
    "Falcon3-3B-Instruct-1.58bit": "http://127.0.0.1:8101",
    "Falcon3-7B-Instruct-1.58bit": "http://127.0.0.1:8102",
    "Falcon3-10B-Instruct-1.58bit": "http://127.0.0.1:8103",
}
DEFAULT_MODEL = "Falcon3-3B-Instruct-1.58bit"

# State
rate_limits: dict[str, list[float]] = {}
security = HTTPBearer(auto_error=False)


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield

app = FastAPI(title="BitNet Inference API", version="2.0.0", lifespan=lifespan)


# Auth
def create_jwt(api_key: str) -> dict:
    now = datetime.now(timezone.utc)
    exp = now + timedelta(hours=JWT_EXPIRY_HOURS)
    token = jwt.encode({"sub": api_key, "iat": now, "exp": exp}, JWT_SECRET, algorithm="HS256")
    return {"token": token, "expires_at": exp.isoformat(), "expires_in_seconds": JWT_EXPIRY_HOURS * 3600}


def verify_token(creds: HTTPAuthorizationCredentials = Depends(security)) -> str:
    if creds is None:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    token = creds.credentials
    if token in API_KEYS:
        return token
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
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


# Models
class Message(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    messages: list[Message]
    model: str = ""
    max_tokens: int = Field(default=512, le=4096)
    temperature: float = Field(default=0.7, ge=0, le=2)
    top_p: float = Field(default=0.9, ge=0, le=1)

class AuthRequest(BaseModel):
    api_key: str


# Endpoints
@app.get("/", response_class=HTMLResponse)
async def chat_ui():
    return FileResponse("server/chat.html")


@app.get("/health")
async def health():
    return {"status": "ok", "models": list(BACKENDS.keys())}


@app.get("/v1/models")
async def list_models():
    return {"data": [{"id": name, "object": "model", "owned_by": "bitnet"} for name in sorted(BACKENDS.keys())]}


@app.post("/v1/auth/token")
async def generate_token(req: AuthRequest):
    if req.api_key not in API_KEYS:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return create_jwt(req.api_key)


@app.post("/v1/chat/completions")
async def chat_completions(req: ChatRequest, caller: str = Depends(verify_token)):
    model_name = req.model if req.model in BACKENDS else DEFAULT_MODEL
    backend_url = BACKENDS[model_name]

    payload = {
        "model": model_name,
        "messages": [{"role": m.role, "content": m.content} for m in req.messages],
        "max_tokens": req.max_tokens,
        "temperature": req.temperature,
        "top_p": req.top_p,
    }

    start = time.time()
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        resp = await client.post(f"{backend_url}/v1/chat/completions", json=payload)
        if resp.status_code != 200:
            raise HTTPException(status_code=504, detail=f"runtime returned HTTP {resp.status_code}")
        data = resp.json()

    elapsed = time.time() - start
    logger.info(f"model={model_name} tokens={req.max_tokens} time={elapsed:.1f}s")

    # Normalize response
    data["model"] = model_name
    data["usage"]["elapsed_ms"] = int(elapsed * 1000)
    return JSONResponse(content=data)
