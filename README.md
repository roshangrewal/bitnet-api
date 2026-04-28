# ⚡ BitNet API

Run 1-bit LLMs on CPU with an OpenAI-compatible API. No GPU required.

Built on [Microsoft BitNet](https://github.com/microsoft/BitNet) — the official inference framework for 1.58-bit ternary LLMs.

## Features

- **CPU-only inference** — runs on any machine, no GPU needed
- **OpenAI SDK compatible** — drop-in replacement, works with Python/JS SDKs
- **Multiple models** — switch between 3B, 7B, 10B models on the fly
- **JWT authentication** — secure token-based auth with 1-hour expiry
- **Rate limiting** — per-key request throttling (30 req/min)
- **Sampling controls** — temperature, top_p, top_k, min_p, repeat/presence/frequency penalties
- **Web chat UI** — dark/light theme, model selection, prompt suggestions
- **API docs page** — interactive token generator, copy-to-clipboard, code examples
- **One-command setup** — single script checks prerequisites, downloads, builds, and runs

## Prerequisites

| Requirement | Why | Install |
|---|---|---|
| **conda** | Python environment manager | [miniconda](https://docs.conda.io/en/latest/miniconda.html) |
| **git** | Clone repo + submodules | `brew install git` / `apt install git` |
| **clang** | Compile the C++ inference engine | macOS: `xcode-select --install` · Linux: `apt install clang` |

### Per-Model Requirements

| Model | Disk (setup) | Disk (final) | RAM | CPU |
|---|---|---|---|---|
| Falcon3-3B | ~15GB temp | 2.1GB | 4GB+ | Any (2+ cores) |
| Falcon3-7B | ~35GB temp | 3.1GB | 8GB+ | Any (4+ cores) |
| Falcon3-10B | ~60GB temp | 4.5GB | 12GB+ | Any (4+ cores) |

> **Disk (setup)** is temporary — the large intermediate file is auto-deleted after conversion. Only **Disk (final)** stays on your machine.

## Quick Start

> **Prerequisites:** [conda](https://docs.conda.io/en/latest/miniconda.html) and git

```bash
# Clone
git clone https://github.com/AiCodingBattle/bitnet-api.git
cd bitnet-api

# Setup (downloads model, builds everything — takes ~10 min)
bash setup.sh        # Falcon3-7B (recommended)
bash setup.sh 3b     # Falcon3-3B (faster, less disk)

# Run
conda activate bitnet-cpp
./server/start.sh
```

Open **http://localhost:8000** for the chat UI.

## Use with OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="sk-local-bitnet-key",  # default local key
)

response = client.chat.completions.create(
    model="Falcon3-7B-Instruct-1.58bit",
    messages=[{"role": "user", "content": "What is Bitcoin?"}],
    temperature=0.7,
    top_p=0.9,
)
print(response.choices[0].message.content)
```

Works with the JavaScript SDK too:

```javascript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'http://localhost:8000/v1',
  apiKey: 'sk-local-bitnet-key',
});

const resp = await client.chat.completions.create({
  model: 'Falcon3-7B-Instruct-1.58bit',
  messages: [{ role: 'user', content: 'What is Bitcoin?' }],
});
console.log(resp.choices[0].message.content);
```

## Authentication

The API uses JWT tokens for authentication.

**Local mode:** Default key `sk-local-bitnet-key` is pre-configured — just start and use.

**Production/Cloud:** Set your own keys via `API_KEYS` env var:

```bash
API_KEYS="sk-prod-key-1,sk-prod-key-2" ./server/start.sh
```

### JWT Token Flow

```bash
# 1. Exchange API key for a JWT token (valid 1 hour)
curl -X POST http://localhost:8000/v1/auth/token \
  -H "Content-Type: application/json" \
  -d '{"api_key": "sk-local-bitnet-key"}'

# Returns: {"token": "eyJ...", "expires_in_seconds": 3600}

# 2. Use the token for requests
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello!"}]}'
```

You can also pass the raw API key directly as a Bearer token (simpler for server-to-server).

## Sampling Parameters

All standard LLM sampling parameters are supported:

| Parameter | Default | Description |
|---|---|---|
| `temperature` | 0.7 | Randomness (0 = deterministic, 2 = max creative) |
| `top_p` | 0.9 | Nucleus sampling threshold |
| `top_k` | 40 | Top-k token filtering |
| `min_p` | 0.1 | Minimum probability threshold |
| `repeat_penalty` | 1.0 | Penalize repeated sequences |
| `presence_penalty` | 0.0 | Encourage new topics |
| `frequency_penalty` | 0.0 | Reduce repetition |

### Recommended Presets

| Use Case | temperature | top_p | top_k |
|---|---|---|---|
| Factual Q&A / Classification | 0.1 | 0.5 | 10 |
| General chat | 0.7 | 0.9 | 40 |
| Creative writing | 1.2 | 0.95 | 100 |
| Code generation | 0.3 | 0.8 | 20 |

## Available Models

| Model | GGUF Size | Speed (M4) | Best For |
|---|---|---|---|
| `bash setup.sh 3b` — Falcon3-3B | 2.1GB | ~25 tok/s | Fast responses |
| `bash setup.sh` — Falcon3-7B | 3.1GB | ~11 tok/s | **Best quality/speed balance** |
| `bash setup.sh 10b` — Falcon3-10B | ~4.5GB | ~7 tok/s | Best quality (needs 60GB free disk for setup) |

You can install multiple models and switch between them in the chat UI.

## Web Interface

### Chat UI — `http://localhost:8000`

- Dark/light theme toggle (persists across sessions)
- Model selector in compose bar
- Clickable prompt suggestions
- Response time and model name shown per message
- JWT token auto-managed (fetched from API key, cached, auto-refreshes)

### API Docs — `http://localhost:8000/v1/docs`

- Interactive token generator with copy buttons
- Ready-to-use BASE_URL and TOKEN values
- Auto-generated curl command
- Full parameter reference with recommended presets
- Code examples: Python, JavaScript, cURL
- Dark/light theme synced with chat UI

## Cloud Deployment

For hosting a public API:

```bash
scp server/cloud-setup.sh user@YOUR_VM_IP:~/
ssh user@YOUR_VM_IP
API_KEYS="sk-your-key" bash cloud-setup.sh
```

Sets up systemd service + Nginx reverse proxy. Requires Ubuntu 22.04+, 8+ vCPU, 16GB+ RAM.

## Configuration

All via environment variables:

| Variable | Default | Description |
|---|---|---|
| `API_KEYS` | `sk-local-bitnet-key` | Comma-separated API keys |
| `JWT_SECRET` | auto-generated | Secret for signing JWT tokens |
| `JWT_EXPIRY_HOURS` | `1` | Token validity period |
| `MAX_CONCURRENT` | `2` | Max simultaneous requests |
| `RATE_LIMIT_RPM` | `30` | Requests per minute per key |
| `REQUEST_TIMEOUT` | `120` | Inference timeout (seconds) |
| `THREADS` | `4` | CPU threads for inference |
| `MODEL_PATH` | `models/Falcon3-7B-.../ggml-model-i2_s.gguf` | Default model path |

## API Endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/v1/auth/token` | No | Exchange API key for JWT token |
| `POST` | `/v1/chat/completions` | Yes | Chat completion (OpenAI compatible) |
| `GET` | `/v1/models` | No | List available models |
| `GET` | `/health` | No | Server health and queue status |

## Try It

Public demo API (hosted): `http://YOUR_VM_IP`

```bash
# Get a JWT token
curl -X POST http://YOUR_VM_IP/v1/auth/token \
  -H "Content-Type: application/json" \
  -d '{"api_key": "DEMO_KEY"}'

# Chat
curl -X POST http://YOUR_VM_IP/v1/chat/completions \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello!"}]}'
```

## Benchmarks

Tested across 12 AI task categories on Azure Standard_D4as_v5 (4 vCPU, 16GB RAM, x86).

### Speed

| Model | Tokens/sec | Avg Response Time |
|---|---|---|
| Falcon3-3B-Instruct | ~23 tok/s | ~4-6s |
| Falcon3-7B-Instruct | ~12 tok/s | ~8-12s |
| Falcon3-10B-Instruct | ~10 tok/s | ~10-15s |

### Quality Comparison

| Task | 3B | 7B | 10B |
|---|---|---|---|
| **Small Talk** | ✅ Short but fine | ✅ Natural, polished | ✅ Natural, polished |
| **Intent Classification** | ❌ Wrong ("greeting") | ✅ Correct ("request") | ⚠️ Close ("inquiry") |
| **Sentiment Analysis** | ⚠️ "negative" (should be mixed) | ✅ **"mixed"** | ⚠️ "negative" |
| **Topic Classification** | ✅ "technology" | ✅ "finance" | ✅ "finance" |
| **Entity Extraction (NER)** | ⚠️ Partial, missing person | ⚠️ Missing person | ✅ **All entities correct** |
| **Reading Comprehension** | ❌ Hallucinated price ($850) | ✅ **Complete + accurate** | ✅ **Complete + accurate** |
| **Summarization** | ✅ Good, slight inaccuracy | ✅ Good | ⚠️ Factual error |
| **Code Explanation** | ✅ Correct | ✅ Detailed + correct | ✅ Correct |
| **Formal Rewriting** | ✅ Good | ✅ **Polished, professional** | ✅ Good |
| **Bullet Point Extraction** | ⚠️ Verbose, added extra info | ✅ **Clean, all 4 points** | ✅ **Clean, all 4 points** |
| **Math (25% of 200)** | ❌ Wrong (said 5) | ⚠️ Started but cut off | ⚠️ Started but cut off |
| **Email Summary + Actions** | ✅ Listed actions | ✅ **Concise one-liner** | ✅ **Detailed with all items** |

### Detailed Results

#### Entity Extraction (NER)

```
Prompt: Extract entities as JSON: "Elon Musk announced on Jan 15 2025 that
        Tesla will open a factory in Berlin with BMW."

3B: {"name": "Tesla", "organization": ["company"], "location": ["Berlin"],
     "date": ["15, 2025"]}
    ⚠️ Missing person (Elon Musk), malformed date

7B: {"location": "Berlin", "organization": "BMW", "date": "Jan 15, 2025"}
    ⚠️ Missing person, missing Tesla

10B: {"person": ["Elon Musk"], "organization": ["Tesla", "BMW"],
      "location": ["Berlin"], "date": "Jan 15 2025"}
     ✅ All entities correctly extracted
```

#### Reading Comprehension

```
Prompt: "Enterprise plan costs $99/month with unlimited storage, dedicated
         account manager, and 99.9% SLA. What does it include and cost?"

3B: "Enterprise plan costs 850 dollars a year..."
    ❌ Hallucinated price

7B: "Enterprise plan includes unlimited storage, a dedicated account manager,
     and has a 99.9% SLA. The cost is $99 per month."
    ✅ Complete and accurate

10B: "The enterprise plan includes unlimited storage and a dedicated account
      manager. It also has a high SLA of 99.9%. The monthly cost is $99."
     ✅ Complete and accurate
```

#### Formal Rewriting

```
Prompt: Rewrite formally: "hey dude meeting pushed to next week cuz client
        bailed lmk if that works"

3B: "Subject: Meeting Adjusted for Client's Availability - Next Week
     Dear [Client's Name],"
    ✅ Good structure

7B: "Good morning [Client's Name], I would like to inform you of an upcoming
     engagement which has been rescheduled for the subsequent week. Kindly
     advise on your availability."
    ✅ Polished, natural tone

10B: "Subject: Client Meeting Reschedule to Next Week
      Dear [Client's Name],"
     ✅ Professional
```

#### Email Summary

```
Prompt: Summarize email and list action items: "Q3 launch moved from Sep 15
        to Oct 1. Marketing update by Sep 20. Budget +15%. Design finalize
        landing page by Sep 25."

3B: "- Update marketing materials
     - Ensure legal documentation finalized
     - Adjust budget allocation"
    ✅ Actions listed, added extra inference

7B: "Q3 launch was delayed; marketing must update by Sept. 20, budget
     increased 15%, and design must complete landing page by Sept. 25"
    ✅ Concise one-sentence summary with all details

10B: "The Q3 launch has been postponed due to regulatory delays. Marketing
      must update materials by September 20, while the budget will be
      increased by 15%. Design team needs to finalize landing page by Sep 25."
     ✅ Most detailed and complete
```

### Verdict

| Model | Best For | Weakness |
|---|---|---|
| **3B** | Fast responses, simple Q&A, topic classification | Hallucinations, weak on nuanced tasks |
| **7B** | **Best all-rounder** — accurate comprehension, clean formatting, good classification | Slower than 3B |
| **10B** | Entity extraction, detailed responses, complex tasks | Slowest, marginal gain over 7B on most tasks |

**Recommendation:** Use **7B as default** for the best quality/speed balance. Use 3B when speed matters more than accuracy. Use 10B for tasks requiring precise entity extraction or detailed analysis.

See [BENCHMARKS.md](BENCHMARKS.md) for full detailed results with actual model responses for every category.

## Documentation

See [DOCS.md](DOCS.md) for:
- Detailed benchmark results (BitNet 2B vs Falcon3 3B vs 7B)
- Full benchmark output with actual model responses
- Cloud deployment guide with systemd + Nginx + HTTPS
- Known issues and workarounds

## License

MIT — see [LICENSE](LICENSE).
