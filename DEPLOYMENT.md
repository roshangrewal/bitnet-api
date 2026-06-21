# BitNet API — Deployment Guide

Deploy all 3 Falcon3 BitNet models (3B, 7B, 10B) with OpenAI-compatible API.

## Architecture

```
Client → UIG (:8000) → bitnet-api FastAPI (:8100) → llama-server backends
                                                      ├── 3B  (:8101)
                                                      ├── 7B  (:8102)
                                                      └── 10B (:8103)
```

## Prerequisites

- Ubuntu 22.04+
- 8+ CPU cores (x86_64 with AVX2)
- 16+ GB RAM (models use ~10GB total)
- clang 18+, cmake 3.22+
- conda (miniconda)

## Setup

### 1. Clone and build

```bash
git clone https://github.com/roshangrewal/bitnet-api.git /data/bitnet-api
cd /data/bitnet-api

conda create -n bitnet-cpp python=3.9
conda activate bitnet-cpp
pip install -r requirements.txt
pip install fastapi uvicorn httpx pyjwt

# Build (includes kernel patches for stability)
python setup_env.py -md models/Falcon3-3B-Instruct-1.58bit -q i2_s
```

### 2. Kernel patches (critical for stability)

Two patches are required to prevent segfaults on 7B/10B models:

**Patch 1 — `src/ggml-bitnet-mad.cpp`**

Force safe 1x1 kernel path. Add early return at the top of `ggml_vec_dot_i2_i8_s`:

```c
void ggml_vec_dot_i2_i8_s(int n, float * s, size_t bs, const void * vx, size_t bx, const void * vy, size_t by, int nrc) {
    // PATCH: force safe 1x1 path
    ggml_vec_dot_i2_i8_s_1x1(n, s, bs, vx, bx, vy, by, nrc);
    return;
    // ... rest of function unchanged
}
```

**Patch 2 — `3rdparty/llama.cpp/ggml/src/ggml.c`**

Disable the 16-row batch fast path for I2_S. Find this line (~line 12504):

```c
if (src0->type == GGML_TYPE_I2_S && iir0 + blck_0 - 1 < ir0_end) {
```

Change to:

```c
if (0 && src0->type == GGML_TYPE_I2_S && iir0 + blck_0 - 1 < ir0_end) {
```

**Patch 3 — `src/ggml-bitnet-mad.cpp` (const fix)**

Fix the const-correctness issue in `ggml_vec_dot_i2_i8_s_Nx1` (~line 811):

```c
// Change:
int8_t * y_col = y + col * by;
// To:
const int8_t * y_col = y + col * by;
```

After patches, rebuild:

```bash
touch src/ggml-bitnet-mad.cpp 3rdparty/llama.cpp/ggml/src/ggml.c
rm -f build/bin/llama-server build/bin/llama-cli
cmake --build build --config Release
```

### 3. Download models

```bash
cd /data/bitnet-api
# Models should be in:
# models/Falcon3-3B-Instruct-1.58bit/ggml-model-i2_s.gguf
# models/Falcon3-7B-Instruct-1.58bit/ggml-model-i2_s.gguf
# models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf

# If not present, use setup_env.py to download:
python setup_env.py --hf-repo tiiuae/Falcon3-3B-Instruct-1.58bit -q i2_s
python setup_env.py --hf-repo tiiuae/Falcon3-7B-Instruct-1.58bit -q i2_s
python setup_env.py --hf-repo tiiuae/Falcon3-10B-Instruct-1.58bit -q i2_s
```

### 4. Create systemd services

```bash
sudo tee /etc/systemd/system/bitnet-3b.service > /dev/null << 'SVC'
[Unit]
Description=BitNet Falcon3-3B llama-server
After=network.target

[Service]
Type=simple
WorkingDirectory=/data/bitnet-api
ExecStart=/data/bitnet-api/build/bin/llama-server -m models/Falcon3-3B-Instruct-1.58bit/ggml-model-i2_s.gguf -c 4096 -t 4 -n 4096 -ngl 0 --host 127.0.0.1 --port 8101 -cb -b 1
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC

sudo tee /etc/systemd/system/bitnet-7b.service > /dev/null << 'SVC'
[Unit]
Description=BitNet Falcon3-7B llama-server
After=network.target

[Service]
Type=simple
WorkingDirectory=/data/bitnet-api
ExecStart=/data/bitnet-api/build/bin/llama-server -m models/Falcon3-7B-Instruct-1.58bit/ggml-model-i2_s.gguf -c 4096 -t 4 -n 4096 -ngl 0 --host 127.0.0.1 --port 8102 -cb -b 1
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC

sudo tee /etc/systemd/system/bitnet-10b.service > /dev/null << 'SVC'
[Unit]
Description=BitNet Falcon3-10B llama-server
After=network.target

[Service]
Type=simple
WorkingDirectory=/data/bitnet-api
ExecStart=/data/bitnet-api/build/bin/llama-server -m models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf -c 4096 -t 4 -n 4096 -ngl 0 --host 127.0.0.1 --port 8103 -cb -b 1
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC

sudo tee /etc/systemd/system/bitnet-api.service > /dev/null << 'SVC'
[Unit]
Description=BitNet API FastAPI Router
After=network.target bitnet-3b.service bitnet-7b.service bitnet-10b.service
Wants=bitnet-3b.service bitnet-7b.service bitnet-10b.service

[Service]
Type=simple
WorkingDirectory=/data/bitnet-api
Environment=PATH=/home/ubuntu/miniconda3/envs/bitnet-cpp/bin:/usr/bin:/bin
Environment=API_KEYS=sk-bitnet-G0ewUFUl2w9NAdF5WugLZ-WK-T0gkOzzJrO5oxCAn_w
Environment=REQUEST_TIMEOUT=300
Environment=MAX_CONCURRENT=1000
Environment=RATE_LIMIT_RPM=3600
ExecStart=/home/ubuntu/miniconda3/envs/bitnet-cpp/bin/uvicorn server.app:app --host 0.0.0.0 --port 8100
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC

sudo systemctl daemon-reload
sudo systemctl enable bitnet-3b bitnet-7b bitnet-10b bitnet-api
sudo systemctl start bitnet-3b bitnet-7b bitnet-10b
sleep 15
sudo systemctl start bitnet-api
```

### 5. Verify

```bash
# Check all services
sudo systemctl status bitnet-3b bitnet-7b bitnet-10b bitnet-api

# Health checks
curl http://localhost:8100/health
curl http://localhost:8101/health
curl http://localhost:8102/health
curl http://localhost:8103/health

# Test inference
curl -s http://localhost:8100/v1/chat/completions \
  -H "Authorization: Bearer sk-bitnet-G0ewUFUl2w9NAdF5WugLZ-WK-T0gkOzzJrO5oxCAn_w" \
  -H "Content-Type: application/json" \
  -d '{"model":"Falcon3-7B-Instruct-1.58bit","messages":[{"role":"user","content":"Hello"}],"max_tokens":20}'
```

## Operations

```bash
# Restart all
sudo systemctl restart bitnet-3b bitnet-7b bitnet-10b bitnet-api

# View logs
journalctl -u bitnet-7b -f
journalctl -u bitnet-api -f

# Alternative manual management
cd /data/bitnet-api
./bitnet.sh start|stop|restart|status|logs
```

## Key Configuration

| Parameter | Value | Why |
|-----------|-------|-----|
| `-b 1` | Batch size 1 | Prevents segfault on 7B/10B with long prompts |
| `-c 4096` | Context window | Max prompt + generation tokens |
| `-t 4` | Threads per model | 3 models × 4 = 12 threads on 8 cores (acceptable overlap) |
| `-cb` | Continuous batching | Allows request queuing |
| `-ngl 0` | No GPU layers | CPU-only inference (BitNet kernels are CPU-optimized) |

## Performance

| Model | 5 tokens | 50 tokens | Prompt eval |
|-------|----------|-----------|-------------|
| 3B | ~350ms | ~2.5s | ~30 tok/s |
| 7B | ~650ms | ~5s | ~28 tok/s |
| 10B | ~870ms | ~7s | ~22 tok/s |

Throughput: ~120 req/min (5 tokens) across all 3 models combined.

## Known Limitations

- CPU-only: ~0.5-1 tok/s generation per model (prompt eval is fast at 22-30 tok/s)
- Single slot per model: requests queue sequentially
- BitNet kernel bug: without the patches + `-b 1`, 7B/10B segfault on prompts >320 tokens
- No GPU support for Falcon3 BitNet models (official GPU kernel only supports BitNet-2B)

## Troubleshooting

**Server crashes and restarts repeatedly:**
```bash
journalctl -u bitnet-7b --no-pager -n 50
```
Usually means the kernel patch wasn't applied or `-b 1` is missing.

**Slow responses:**
Normal — BitNet CPU inference is ~0.5 tok/s generation. Prompt eval is fast (22-30 tok/s).

**504 Gateway Timeout:**
Increase `REQUEST_TIMEOUT` in bitnet-api.service if using long `max_tokens`.
