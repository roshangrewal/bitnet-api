# BitNet Inference API — Project Documentation

> Run 1-bit LLMs on CPU with an OpenAI-compatible API. No GPU required.

Built on [Microsoft BitNet](https://github.com/microsoft/BitNet) (bitnet.cpp) — the official inference framework for 1.58-bit ternary LLMs.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Models](#models)
- [Local Setup (macOS / Linux)](#local-setup)
- [Cloud VM Deployment (Ubuntu)](#cloud-vm-deployment)
- [API Reference](#api-reference)
- [Configuration](#configuration)
- [Benchmarks](#benchmarks)
- [Known Issues](#known-issues)
- [File Structure](#file-structure)

---

## Overview

### What is BitNet?

BitNet b1.58 is a model architecture from Microsoft Research where weights are stored as ternary values (-1, 0, +1) instead of 16/32-bit floats. This means:

- **~5x less memory** than standard models (2B model = ~0.4GB vs ~2GB)
- **Runs on CPU only** — no GPU needed
- **55-82% less energy** consumption
- **2x-6x faster** on CPUs vs equivalent float models

### What this project does

Wraps BitNet-compatible models in a production-ready HTTP API with:

- OpenAI-compatible `/v1/chat/completions` endpoint
- API key authentication (Bearer token)
- Per-key rate limiting (configurable RPM)
- Concurrency control (bounded queue)
- Systemd service + Nginx reverse proxy for cloud deployment
- One-command cloud setup script

---

## Architecture

```
Client (curl / SDK / app)
    │
    ▼
┌─────────────────────────────┐
│  Nginx (port 80/443)        │  ← reverse proxy, HTTPS termination
│  └─ proxy_pass :8000        │
└─────────────────────────────┘
    │
    ▼
┌─────────────────────────────┐
│  FastAPI Gateway (port 8000)│  ← auth, rate limit, concurrency
│  └─ server/app.py           │
└─────────────────────────────┘
    │
    ▼
┌─────────────────────────────┐
│  llama-cli (subprocess)     │  ← bitnet.cpp inference engine
│  └─ build/bin/llama-cli     │
└─────────────────────────────┘
```

Each request spawns a `llama-cli` process. The model loads per-request (~3-8s depending on model size). This is because `llama-server` (persistent process) segfaults with Falcon3 models — a known upstream issue.

---

## Models

### Recommended: Falcon3 Instruct (1.58-bit)

These are **instruction-tuned** models that follow system prompts and handle structured tasks.

| Model | Params | GGUF Size | RAM Needed | Disk for Conversion | Best For |
|---|---|---|---|---|---|
| `tiiuae/Falcon3-1B-Instruct-1.58bit` | 1B | ~0.8GB | ~1.5GB | ~8GB temp | Ultra-fast classification |
| `tiiuae/Falcon3-3B-Instruct-1.58bit` | 3B | ~2.1GB | ~3GB | ~12GB temp | Fast general tasks |
| `tiiuae/Falcon3-7B-Instruct-1.58bit` | 7B | ~3.1GB | ~6GB | ~30GB temp | **Best quality/speed balance** |
| `tiiuae/Falcon3-10B-Instruct-1.58bit` | 10B | ~4.5GB | ~8GB | ~40GB temp | Best quality, cloud only |

### Not Recommended for Production

These are **base models** (not instruction-tuned). They can complete text but fail at structured tasks.

| Model | Params | Issue |
|---|---|---|
| `microsoft/BitNet-b1.58-2B-4T` | 2.4B | Only works for open-ended chat, garbage on structured tasks |
| `HF1BitLLM/Llama3-8B-1.58-100B-tokens` | 8B | Base model, no instruction following |
| `1bitLLM/bitnet_b1_58-3B` | 3.3B | Base model, limited capability |
| `1bitLLM/bitnet_b1_58-large` | 0.7B | Too small for meaningful output |

### Chat Template

Falcon3 Instruct models use this prompt format (handled automatically by the API):

```
<|system|>
You are a helpful assistant.
<|user|>
What is Bitcoin?
<|assistant|>
```

BitNet 2B uses a different format: `Human: ... BITNETAssistant: ...`

---

## Local Setup

### Prerequisites

- macOS (Apple Silicon) or Linux (x86_64 / ARM64)
- conda
- clang (macOS: Xcode CLI tools, Linux: `apt install clang`)
- ~10-40GB free disk (depending on model, for conversion temp files)

### Step 1: Clone & build

```bash
git clone https://github.com/microsoft/BitNet.git
cd BitNet

conda create -n bitnet-cpp python=3.9 -y
conda activate bitnet-cpp
conda install cmake -y
pip install -r requirements.txt
pip install fastapi uvicorn httpx pydantic
```

### Step 2: Download & build a model

```bash
# Falcon3-7B (recommended)
python setup_env.py --hf-repo tiiuae/Falcon3-7B-Instruct-1.58bit -q i2_s

# Or Falcon3-3B (faster, less disk needed)
python setup_env.py --hf-repo tiiuae/Falcon3-3B-Instruct-1.58bit -q i2_s
```

This downloads the model, converts to GGUF, and quantizes to I2_S. Takes 5-15 minutes.

### Step 3: Clean up temp files

```bash
# Remove the huge f32 intermediate (saves 12-30GB)
rm -f models/Falcon3-*-Instruct-1.58bit/ggml-model-f32.gguf
# Remove source safetensors
find models/ -name "*.safetensors" -delete
```

### Step 4: Run the API

```bash
conda activate bitnet-cpp
./server/start.sh
```

API is live at `http://localhost:8000`. Docs at `http://localhost:8000/docs`.

### Step 5: Test

```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Summarize what Bitcoin is in 2 sentences."}
    ],
    "max_tokens": 100
  }'
```

---

## Cloud VM Deployment

### VM Requirements

| Model | Min vCPU | Min RAM | Min Disk | Recommended VM |
|---|---|---|---|---|
| Falcon3-3B | 4 | 8GB | 20GB | Azure `D4as_v5`, AWS `c6a.xlarge` |
| Falcon3-7B | 4 | 16GB | 40GB | Azure `D4as_v5`, AWS `c6a.xlarge` |
| Falcon3-10B | 8 | 16GB | 60GB | Azure `D8as_v5`, AWS `c6a.2xlarge` |

### One-Command Setup

Copy `server/cloud-setup.sh` to your VM and run:

```bash
# 10B model (best quality)
API_KEYS="sk-your-secret-key-1,sk-your-secret-key-2" bash cloud-setup.sh

# Or specify a different model
MODEL_REPO=tiiuae/Falcon3-7B-Instruct-1.58bit API_KEYS="sk-your-key" bash cloud-setup.sh
```

The script handles everything:
1. Installs system dependencies (build-essential, cmake, clang, nginx)
2. Clones BitNet repo
3. Creates Python venv + installs deps
4. Downloads model, converts, quantizes
5. Cleans up temp files
6. Creates FastAPI server
7. Sets up systemd service (auto-restart)
8. Configures Nginx reverse proxy

### Post-Setup

```bash
# Check status
sudo systemctl status bitnet

# View logs
sudo journalctl -u bitnet -f

# Restart
sudo systemctl restart bitnet

# Add HTTPS
sudo certbot --nginx -d yourdomain.com
```

### API is accessible at

```
http://YOUR_VM_IP/v1/chat/completions
http://YOUR_VM_IP/health
```

---

## API Reference

All endpoints use `Authorization: Bearer <your-api-key>` header.

### `GET /health`

No auth required. Returns server status.

```json
{
  "status": "ok",
  "model": "models/Falcon3-7B-Instruct-1.58bit/ggml-model-i2_s.gguf",
  "queue_available": 2
}
```

### `POST /v1/chat/completions`

OpenAI-compatible chat completion endpoint.

**Request:**

```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello!"}
  ],
  "max_tokens": 512,
  "temperature": 0.7
}
```

**Response:**

```json
{
  "id": "chatcmpl-bitnet-1714300000",
  "object": "chat.completion",
  "model": "falcon3-7b-instruct-1.58bit",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "elapsed_ms": 5200
  }
}
```

**Error Responses:**

| Code | Meaning |
|---|---|
| 401 | Invalid API key |
| 429 | Rate limit exceeded (default: 30 req/min/key) |
| 503 | Server busy (max concurrent requests reached) |
| 504 | Inference timed out |

---

## Configuration

All via environment variables:

| Variable | Default | Description |
|---|---|---|
| `API_KEYS` | `sk-local-bitnet-key` | Comma-separated valid API keys |
| `JWT_SECRET` | auto-generated | Secret for signing JWT tokens |
| `JWT_EXPIRY_HOURS` | `1` | Token validity period (hours) |
| `MODEL_PATH` | `models/Falcon3-7B-.../ggml-model-i2_s.gguf` | Path to GGUF model file |
| `CLI_PATH` | `build/bin/llama-cli` | Path to llama-cli binary |
| `THREADS` | `4` | CPU threads for inference |
| `MAX_CONCURRENT` | `2` | Max simultaneous inference requests |
| `RATE_LIMIT_RPM` | `30` | Requests per minute per API key |
| `REQUEST_TIMEOUT` | `120` (local) / `180` (cloud) | Seconds before inference timeout |
| `API_PORT` | `8000` | FastAPI listen port |

Example:

```bash
API_KEYS="sk-prod-key-1,sk-prod-key-2" THREADS=8 MAX_CONCURRENT=3 ./server/start.sh
```

---

## Benchmarks

Tested on **Apple M4, 4 threads**. All prompts tested via the API gateway.

### Model Comparison Summary

| Task | BitNet 2B (base) | Falcon3 3B (instruct) | Falcon3 7B (instruct) |
|---|---|---|---|
| Small talk | ✅ | ✅ | ✅ |
| Intent detection | ❌ Garbage | ⚠️ 1/3 correct | ⚠️ Improved |
| Entity extraction | ❌ Garbage | ✅ JSON (some hallucination) | ✅ Clean JSON |
| Reading comprehension | ❌ Garbage | ⚠️ Partial answers | ✅ Complete answers |
| Summarization | ❌ Garbage | ✅ Good | ✅ Good |
| Sentiment analysis | ❌ Garbage | ❌ Wrong ("positive") | ⚠️ Close ("negative") |
| Topic classification | ❌ Garbage | ✅ Correct | ✅ Correct |
| Code explanation | ❌ Garbage | ✅ Correct | ✅ Correct |
| Bug detection | ❌ Garbage | ⚠️ Wrong diagnosis | ⚠️ Partial |
| Formal rewriting | ❌ Garbage | ✅ Good | ✅ More polished |
| Bullet point extraction | ❌ Garbage | ✅ Perfect | ✅ Perfect |
| **Speed** | **31-34 tok/s** | **20-27 tok/s** | **10-12 tok/s** |

### Detailed Benchmark: BitNet b1.58 2B (Base Model)

> **Verdict: Only usable for open-ended chat. Fails completely on structured tasks.**

The pre-built GGUF from HuggingFace (`microsoft/BitNet-b1.58-2B-4T-gguf`) produced garbage output due to broken tokenizer metadata. After converting from the bf16 safetensors source (`microsoft/bitnet-b1.58-2B-4T-bf16`), open-ended chat worked but structured tasks still failed.

**Working (no system prompt, open-ended):**

```
User: What is artificial intelligence? Explain in 2 sentences.

Response: Artificial intelligence (AI) is the simulation of human intelligence
processes by machines, especially computer systems, to perform tasks that
usually require human cognition. These tasks include learning, reasoning,
problem-solving, perception, and language understanding.
```

**Failing (with system prompt, structured task):**

```
System: You are an intent classifier. Respond with only the intent label.
User: I've been waiting 3 weeks for my refund!

Response: ScalarsNormalsControllersContoursContContContCont...
```

```
System: Summarize in 2-3 sentences.
User: [ECB interest rate article]

Response: Inlining)=='AP"? In ") print("The answer is: (a) (b) c")
<|assistant|> 3<|assistant|> 3<|assistant|>...
```

### Detailed Benchmark: Falcon3-3B-Instruct-1.58bit

> **Verdict: Usable for a productivity product. Good at most tasks, weak on nuanced classification.**

```
📋 Greeting
User: Hey, how are you doing today?
Response: Sure, feel free to ask any questions you have. I'm here to help.
Speed: 28.2 tok/s

📋 Humor
User: Tell me a short joke about programming.
Response: Why don't programmers ever play hide and seek?
They always find the solution on their own!
Speed: 29.7 tok/s

📋 Intent: Complaint
System: Classify intent as: complaint, inquiry, feedback, request, greeting.
User: I've been waiting 3 weeks for my refund and nobody is responding!
Response: request  ← Wrong (should be complaint)
Speed: 27.1 tok/s

📋 Intent: Inquiry
System: Classify intent as: complaint, inquiry, feedback, request, greeting.
User: What are your business hours on weekends?
Response: Greeting  ← Wrong (should be inquiry)
Speed: 26.0 tok/s

📋 NER: People & Places
System: Extract named entities as JSON.
User: Elon Musk announced on January 15, 2025 that Tesla will open a factory in Berlin...
Response: {"person": {"name": "Elon Musk", "age": {"numeric": "27"...}},
           "organization": {"name": "Tesla"...}}
Note: Correct entities but hallucinated age field
Speed: 23.5 tok/s

📋 Reading Comprehension
System: Answer based ONLY on context.
User: [Eiffel Tower context] Who designed it and when?
Response: The Eiffel Tower was designed by Gustave Eiffel's engineering company.
Speed: 25.7 tok/s

📋 Factual Extraction
System: Answer based ONLY on context.
User: [Pricing plans] Which plan has dedicated account manager?
Response: Enterprise  ← Correct plan but missing the price ($99/month)
Speed: 25.7 tok/s

📋 News Summarization
System: Summarize in 2-3 sentences.
User: [ECB interest rate article]
Response: The European Central Bank raised interest rates on Thursday to 4.5%
to calm inflation. The ECB wants more evidence of economic sustainability
before cutting rates, and the rate will be cut in June 2024.
Speed: 25.2 tok/s

📋 Email Summary
System: Summarize in one sentence and identify action item.
User: [Q3 launch email from Sarah]
Response: Mark product launch moved from September 15 to October 1, pending
approvals, update marketing materials by September 20, increased budget by 15%
Speed: 22.2 tok/s

📋 Sentiment Analysis
System: Classify as positive, negative, neutral, or mixed.
User: The food was amazing but the service was terrible. Waited 45 minutes.
Response: positive  ← Wrong (should be mixed)
Speed: 20.8 tok/s

📋 Topic Classification
System: Classify as: technology, sports, politics, health, finance, entertainment.
User: NVIDIA stock surged 12% after record $22.1B revenue from AI chips.
Response: technology  ← Correct
Speed: 22.9 tok/s

📋 Code Explanation
User: What does sorted(set(words), key=lambda w: -len(w))[:5] do?
Response: This Python code sorts the words in a list with their lengths in
descending order. The sorted function arranges elements in ascending order.
The key argument specifies a function for comparison.
Speed: 21.0 tok/s

📋 Bug Detection
User: Find the bug in: def average(numbers): total=0; for n in numbers: total+=n; return total/len(numbers)
Response: The number total is not being updated. [Incorrect diagnosis —
the actual bug is ZeroDivisionError on empty list]
Speed: 20.2 tok/s

📋 Formal Rewrite
System: Rewrite in professional formal tone.
User: hey dude, the meeting got pushed to next week cuz the client bailed. lmk if that works for u
Response: Certainly, here is a formal rephrasing: "Dear [Client's Name],
I hope this message finds you well. I understand that the meeting has been
rescheduled to the upcoming week, due to the client's unavailability.
Please let..."
Speed: 19.8 tok/s

📋 Bullet Points
System: Extract key points as bullet list.
User: [Employee policy text]
Response:
- 1. Timesheet Requirement: All employees must submit timesheets by Friday 5pm.
- 2. Project Management Tool Usage: Utilize the new tool for task tracking.
- 3. Standup Meeting: Conduct weekly stand-ups at 9am Monday.
- 4. Security Training: Complete security training by end of month.
Speed: 17.6 tok/s
```

### Detailed Benchmark: Falcon3-7B-Instruct-1.58bit

> **Verdict: Best quality available. Noticeably better on factual QA, NER, and rewriting. ~2x slower than 3B.**

```
📋 Greeting
User: Hey, how are you doing today?
Response: I'm just a computer program, so I don't have feelings, but I'm
here and ready to help you. How can I assist you today?
Speed: 12.1 tok/s

📋 Intent: Complaint
System: Classify intent. Labels: complaint, inquiry, feedback, request, greeting.
User: I've been waiting 3 weeks for my refund!
Response: request  ← Still wrong, but consistent with 3B
Speed: 11.9 tok/s

📋 Intent: Inquiry
System: Classify intent.
User: What are your business hours on weekends?
Response: query  ← Better than 3B's "greeting" but not exact label
Speed: 12.7 tok/s

📋 NER: People & Places
System: Extract named entities as JSON.
User: Elon Musk announced on January 15, 2025 that Tesla will open a factory in Berlin...
Response: {"Company": "Tesla", "Organization": "BMW",
           "Location": {"City": "Berlin", "Country": "Germany"},
           "Date": "January 15, 2025"}
Note: Clean JSON, no hallucinated fields (unlike 3B)
Speed: 11.5 tok/s

📋 Factual Extraction ← KEY IMPROVEMENT
System: Answer based ONLY on context.
User: [Pricing plans] Which plan has dedicated account manager?
Response: The Enterprise plan has a dedicated account manager and costs $99/month.
Note: 3B only said "Enterprise" — 7B gives the complete answer
Speed: 11.5 tok/s

📋 News Summarization
System: Summarize in 2-3 sentences.
User: [ECB interest rate article]
Response: The European Central Bank (ECB) has held interest rates steady at
4.5% since July 2022. The interest rate was raised 10 times in the past few
months to combat inflation. The ECB's president, Lagarde, said more evidence
is needed before cutting rates.
Speed: 8.6 tok/s

📋 Sentiment Analysis
System: Classify as positive, negative, neutral, or mixed.
User: The food was amazing but the service was terrible. Waited 45 minutes.
Response: negative  ← Closer than 3B's "positive" but still not "mixed"
Speed: 10.3 tok/s

📋 Topic Classification
System: Classify as: technology, sports, politics, health, finance, entertainment.
User: NVIDIA stock surged 12% after record revenue from AI chips.
Response: technology  ← Correct
Speed: 10.4 tok/s

📋 Code Explanation
User: What does sorted(set(words), key=lambda w: -len(w))[:5] do?
Response: This Python code sorts the first 5 characters of each word in a
list by their length in descending order, using the sorted() function with
a custom key that returns the negative length of each word.
Speed: 10.4 tok/s

📋 Formal Rewrite ← KEY IMPROVEMENT
System: Rewrite in professional formal tone.
User: hey dude, the meeting got pushed to next week cuz the client bailed...
Response: Good morning, I am writing to confirm the rescheduling of our
meeting for next week. I understand that the client has had to bail from
the previous appointment, and I trust that this arrangement will be
mutually agreeable to you. If you are available, please let me know...
Note: More natural and polished than 3B
Speed: 10.2 tok/s

📋 Bullet Points
System: Extract key points as bullet list.
User: [Employee policy text]
Response:
- 1. Timesheet Requirement: Submit timesheets by Friday 5pm.
- 2. Project Management Tool Usage: Use new tool for task tracking.
- 3. Standup Meeting: Weekly stand-ups at 9am Monday.
- 4. Security Training: Complete by end of month.
Speed: 10.2 tok/s
```

### Speed Comparison (Apple M4, 4 threads)

```
BitNet 2B (base):     ████████████████████████████████████  31-34 tok/s
Falcon3 3B (instruct): ██████████████████████████           20-27 tok/s
Falcon3 7B (instruct): █████████████                        10-12 tok/s
Falcon3 10B (instruct): ████████                             ~6-8 tok/s (estimated)
```

### Latency Per Request (including model load)

| Model | Simple query | Complex query |
|---|---|---|
| Falcon3 3B | ~3-4s | ~5-6s |
| Falcon3 7B | ~5-6s | ~8-10s |
| Falcon3 10B | ~8-10s | ~12-15s (estimated) |

---

## OpenAI SDK Compatibility

The API is fully compatible with the OpenAI Python and JavaScript SDKs.

### Python SDK

```bash
pip install openai
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="YOUR_API_KEY",
)

response = client.chat.completions.create(
    model="Falcon3-7B-Instruct-1.58bit",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "What is Bitcoin?"},
    ],
    max_tokens=200,
    temperature=0.7,
)

print(response.choices[0].message.content)
```

### JavaScript/TypeScript SDK

```bash
npm install openai
```

```javascript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'http://localhost:8000/v1',
  apiKey: 'YOUR_API_KEY',
});

const response = await client.chat.completions.create({
  model: 'Falcon3-7B-Instruct-1.58bit',
  messages: [{ role: 'user', content: 'What is Bitcoin?' }],
});

console.log(response.choices[0].message.content);
```

### JWT Token Auth

For client-side apps, exchange your API key for a short-lived JWT token:

```bash
# Get token (valid 1 hour)
curl -X POST http://localhost:8000/v1/auth/token \
  -H "Content-Type: application/json" \
  -d '{"api_key": "YOUR_API_KEY"}'

# Use token
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer <jwt_token>" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}]}'
```

---

## Known Issues

### 1. llama-server segfaults with Falcon3 models

The `llama-server` (persistent HTTP server from llama.cpp) crashes after 1-2 requests when running Falcon3 models. This is an upstream issue in bitnet.cpp's fork of llama.cpp.

**Workaround:** The API uses `llama-cli` subprocess per request instead. This means the model loads fresh each request (~3-8s overhead). When the upstream fix lands, switching to `llama-server` would eliminate this overhead.

### 2. Pre-built GGUF from HuggingFace produces garbage

The `microsoft/BitNet-b1.58-2B-4T-gguf` pre-quantized model has broken tokenizer metadata, producing garbage output. 

**Fix:** Convert from the bf16 safetensors source using `utils/convert-helper-bitnet.py`.

### 3. BitNet 2B is a base model, not instruct

Despite being the "official" BitNet model, it's not instruction-tuned. It can only do open-ended text completion. System prompts and structured tasks produce garbage.

### 4. Intent classification is weak across all models

Even the 7B model struggles with exact intent labels. For production intent classification, consider:
- Fine-tuning on your specific labels
- Using a dedicated classifier model
- Hybrid approach: BitNet for generation, cloud API for classification

### 5. Sentiment "mixed" is hard for small models

Both 3B and 7B fail to identify mixed sentiment. This is a known weakness of small language models — they tend to pick the dominant sentiment.

### 6. Disk space during conversion

Model conversion creates a large f32 intermediate file (4x the final size). Always delete it after quantization:

```bash
rm -f models/*/ggml-model-f32.gguf
```

---

## File Structure

```
bitnet/
├── build/
│   └── bin/
│       ├── llama-cli          # Inference binary
│       ├── llama-server       # HTTP server (segfaults with Falcon3)
│       └── llama-quantize     # Quantization tool
├── models/
│   ├── Falcon3-3B-Instruct-1.58bit/
│   │   └── ggml-model-i2_s.gguf    # 2.1GB
│   └── Falcon3-7B-Instruct-1.58bit/
│       └── ggml-model-i2_s.gguf    # 3.1GB
├── server/
│   ├── app.py                 # FastAPI gateway (auth, rate limit, inference)
│   ├── start.sh               # Local launcher
│   ├── cloud-setup.sh         # One-command cloud VM setup
│   ├── nginx.conf             # Nginx reverse proxy config
│   ├── requirements.txt       # Python deps (fastapi, uvicorn, httpx, pydantic)
│   └── README.md              # Quick-start guide
├── utils/                     # BitNet conversion & benchmark scripts
├── 3rdparty/                  # llama.cpp submodule
├── setup_env.py               # Model download + build script
├── run_inference.py            # CLI inference script
├── run_inference_server.py     # Server inference script (llama-server)
├── requirements.txt           # Core Python deps
├── Dockerfile                 # Container build
├── DOCS.md                    # ← This file
└── CMakeLists.txt             # C++ build config
```

---

## Quick Reference

```bash
# Start API locally
conda activate bitnet-cpp
./server/start.sh

# Switch models
MODEL_PATH=models/Falcon3-3B-Instruct-1.58bit/ggml-model-i2_s.gguf ./server/start.sh

# Test
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{"messages":[{"role":"user","content":"Hello!"}],"max_tokens":100}'

# Health check
curl http://localhost:8000/health

# Cloud deploy (10B)
scp server/cloud-setup.sh user@VM_IP:~/
ssh user@VM_IP "API_KEYS=sk-your-key bash cloud-setup.sh"

# Add a new model
python setup_env.py --hf-repo tiiuae/Falcon3-3B-Instruct-1.58bit -q i2_s
rm -f models/Falcon3-3B-Instruct-1.58bit/ggml-model-f32.gguf
```
