# LLM Server

[![Medium](https://img.shields.io/badge/Medium-@kibotu-000000?style=flat-square&logo=medium&logoColor=white)](https://medium.com/@kibotu/two-paths-to-local-llm-servers-windows-nvidia-vs-mac-apple-silicon-1e28d606f600?sk=a5d9989d124d7f9b844927f0f545ed09)

Turn your idle Windows machine with an NVIDIA GPU into a low-latency, private LLM inference server. Docker-based OpenAI-compatible API with usage tracking and optional high-load benchmarking.

## Why

Cloud LLMs are great until you are sending hundreds of agentic round trips, hitting rate limits, or working with code you would rather not leave your network. This project runs Qwen models on your hardware behind an OpenAI-compatible endpoint, with optional Unsloth GGUF add-ons: **Gemma 3 12B IT** and **Gemma 4 26B-A4B IT**. Any client on your network can connect for private inference.

The sweet spot is **agentic work**: tool calling, code generation, multi-step reasoning. Running locally means zero per-token cost, no rate limits, and your code stays on your LAN.

## What You Get

- **OpenAI-compatible API** — works with Cursor, Continue, OpenCode, any OpenAI SDK client
- **Usage tracking** — requests proxied through a tracker on port 8899 with persisted stats
- **Two Qwen models out of the box** — Qwen3.5-9B and Qwen3.5-35B-A3B MoE; optional **Gemma 3 12B** / **Gemma 4 26B-A4B** via setup flags
- **Docker-based** — no CUDA toolkit or building llama.cpp from source
- **Health checks** — containers auto-restart on failure
- **Tailscale-ready** — secure remote access without port forwarding
- **Benchmarking** — Python load tests and result analysis (`benchmark.py`, `analyze-benchmark.py`)

## Requirements

| Component | Minimum |
|-----------|---------|
| GPU | NVIDIA RTX 3060 12 GB |
| RAM | 32 GB |
| OS | Windows 10/11 |
| Docker Desktop | Latest with WSL2 backend |

If you have an NVIDIA GPU with 12+ GB VRAM and Docker Desktop installed, you are set.

---

## Step-by-Step Guide (Windows)

### Step 1: Install Docker Desktop

Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) with the WSL2 backend (default in recent versions).

Verify:

```powershell
docker --version
docker info
```

You should see your GPU under the GPU section of `docker info`. If not, update your NVIDIA drivers.

### Step 2: Clone and Run Setup

```powershell
git clone <this-repo>
cd llm-server
.\setup.ps1
```

Setup verifies GPU visibility, pulls the llama.cpp CUDA image, downloads models, and can add a Windows firewall rule for port 8899. First run may take a while while models download.

**16 GB VRAM (e.g. RTX 4080)** — practical optional add-ons here are **[Gemma 3 12B IT Q4_K_M](https://huggingface.co/unsloth/gemma-3-12b-it-GGUF)** (~7 GB file) and **[Gemma 4 26B-A4B IT UD-Q4_K_M](https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF)** (~16 GB file). *Google’s Gemini is not distributed as local GGUF; the open line is **Gemma**.*

```powershell
.\setup.ps1 -IncludeGemma312   # or: .\setup.ps1 -Model gemma312
.\setup.ps1 -IncludeGemma426BA4B  # or: .\setup.ps1 -Model gemma426ba4b
```

### Step 3: Start the Server

```powershell
.\run.ps1              # 9B model (default)
.\run.ps1 -Model 35b   # 35B model
.\run.ps1 -Model gemma312  # Gemma 3 12B IT
.\run.ps1 -Model gemma426ba4b # Gemma 4 26B-A4B IT
```

The API is at `http://0.0.0.0:8899/v1` (usage tracker proxies to the LLM container).

### Step 4: Verify

```powershell
.\test.ps1
```

From another machine on the LAN:

```powershell
.\test.ps1 -Server 192.168.1.100   # your Windows host IP
```

### Step 5: Quick Token Benchmark (optional)

```powershell
.\benchmark.ps1
```

Use `-Runs 5` for a more stable average.

### Step 6: A/B Performance Tuning (recommended)

Run a controlled baseline, then compare tuned settings on the same model and prompt mix.

```powershell
# A: conservative batching (still uses auto thread count: e.g. 20 on a 32-logical Core i9)
.\run.ps1 -Model 9b -Context 32768 -Threads 0 -Batch 2048 -UBatch 512 -Restart
.\benchmark.ps1 -Runs 5

# B: higher batch / micro-batch (often better on GPU; watch VRAM)
.\run.ps1 -Model 9b -Context 32768 -Threads 0 -Batch 4096 -UBatch 1024 -Restart
.\benchmark.ps1 -Runs 5

# C: same as B but push CPU parallelism (try 16, 20, 24 on i9-13900K and pick the winner)
.\run.ps1 -Model 9b -Context 32768 -Threads 24 -Batch 4096 -UBatch 1024 -Restart
.\benchmark.ps1 -Runs 5
```

Optional speculative decoding test (requires a compatible draft GGUF in `models/`):

```powershell
.\run.ps1 -Model 9b -Context 32768 -Batch 4096 -UBatch 1024 -Threads 0 `
  -DraftModelFile <draft-model.gguf> -DraftMin 4 -DraftMax 12 -Restart
.\benchmark.ps1 -Runs 5
```

Notes:
- Keep context fixed for fair A/B comparisons.
- `-Threads 0` selects an auto thread count from your CPU (see **LLM tuning parameters** below).
- Draft model should share tokenizer family with the main model.
- If speculative decoding regresses speed, reduce `-DraftMax` or use a smaller draft model.

---

## Context Size: 32k vs 128k

Default context is 32k (see `run.ps1` / `.env`). For 128k:

```powershell
cp .env.128k .env
docker compose restart llm
```

Or start the stack with compose directly:

```powershell
docker compose up -d
```

---

## Python Load Benchmarking

For deeper load tests and saved reports:

```powershell
pip install -r requirements-benchmark.txt
python benchmark.py --test standard
```

Helper scripts:

```powershell
.\run-benchmark.ps1 standard   # Windows
./run-benchmark.sh standard    # Linux/Mac
```

### Benchmark Test Suites

- `quick` — short run (~30s)
- `standard` — recommended (~5–10 min)
- `stress` — high load (~10–15 min)
- `context-scaling` — 1k through 128k contexts (~15–20 min)
- `all` — full suite (~30–45 min)

### Analyze Results

```powershell
python analyze-benchmark.py benchmark_results.json
python analyze-benchmark.py benchmark_results.json --all
```

---

## Expected Performance (RTX 4080, 16 GB VRAM)

| Context | RPS | Latency (P50) | VRAM |
|---------|-----|---------------|------|
| 1k | 5–10 | 200–500 ms | ~8 GB |
| 10k | 2–5 | 500–2000 ms | ~9 GB |
| 50k | 0.5–1.5 | 2–5 s | ~12 GB |
| 100k | 0.2–0.5 | 5–15 s | ~15 GB |
| 128k | 0.1–0.3 | 10–30 s | ~16 GB |

**Approximate max context before VRAM pressure: ~138k tokens**

### Monitor GPU

```bash
nvidia-smi -l 1
```

---

## Connect Your Clients

The server is OpenAI-compatible. Set the base URL to `http://<windows-ip>:8899/v1` (or Tailscale IP).

**OpenCode** — add a provider in `~/.config/opencode/opencode.json` (Linux/Mac) or the equivalent config path on Windows:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama-at-home": {
      "name": "Llama.cpp (local)",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://<windows-ip>:8899/v1"
      },
      "models": {
        "Qwen3.5-9B": {
          "name": "Qwen3.5-9B"
        },
        "Qwen3.5-35B-A3B": {
          "name": "Qwen3.5-35B-A3B"
        },
        "gemma-3-12b-it-Q4_K_M": {
          "name": "gemma-3-12b-it-Q4_K_M"
        },
        "gemma-4-26B-A4B-it-UD-Q4_K_M": {
          "name": "gemma-4-26B-A4B-it-UD-Q4_K_M"
        }
      }
    }
  }
}
```

Replace `<windows-ip>` with your LAN or Tailscale address. Restart OpenCode so models appear in the selector.

**Cursor / Continue / OpenAI SDK** — set base URL to `http://<windows-ip>:8899/v1`. API key can be any string if the server does not enforce auth.

---

## Access Over Tailscale (optional)

1. Install [Tailscale](https://tailscale.com) on the Windows host and on clients.
2. Use the Tailscale IP (`100.x.x.x`) as `<windows-ip>`.

```powershell
tailscale ip -4
```

---

## Model Selection

| Model | Size | Speed | When to Use |
|-------|------|-------|-------------|
| Qwen3.5-9B | ~5 GB | fast | Default: agentic loops, edits, chat |
| Qwen3.5-35B-A3B | ~21 GB | slower | Harder reasoning; tight on 16 GB VRAM |
| Gemma 3 12B IT Q4_K_M | ~7 GB | medium | Strong general + IT model; fits 16 GB VRAM with context headroom |
| Gemma 4 26B-A4B IT UD-Q4_K_M | ~16-17 GB | medium | Gemma 4 Q4 option; significantly heavier than 9B/12B class models |

Only one model is loaded at a time; switch with `.\run.ps1 -Model … -Restart`.

```powershell
.\run.ps1 -Model 35b -Restart
.\run.ps1 -Model gemma312 -Restart
.\run.ps1 -Model gemma426ba4b -Restart
.\run.ps1 -Restart
```

### Run.ps1 Options

```powershell
.\run.ps1 -Context 16384   # smaller context (saves VRAM)
.\run.ps1 -Thinking       # extended reasoning mode
.\run.ps1 -Batch 4096 -UBatch 1024        # throughput tuning (threads: default auto, or -Threads 24)
.\run.ps1 -DraftModelFile <draft-model.gguf> -DraftMin 4 -DraftMax 12  # speculative decode
.\run.ps1 -Stop           # stop stack
```

---

## LLM tuning parameters (llama.cpp)

These map to the `llm` service command in `docker-compose.yml`. `run.ps1` sets the env vars; you can also set them in a root `.env` file for `docker compose`.

| Flag / setting | Env / `run.ps1` | What it does | Typical range to try |
|----------------|-----------------|--------------|----------------------|
| `-m` | `MODEL_FILE` | Main GGUF filename under `models/`. | Your downloaded models. |
| `-c` | `CONTEXT_SIZE` / `-Context` | Max context length (token slots). Lower saves VRAM and speeds prefill. | 4096–131072 (keep at what you actually need). |
| `-ctk` / `-ctv` | (fixed in compose) | KV cache tensor type for keys/values (`q4_0` here: smaller cache). | Other types per llama.cpp docs if you change the image flags. |
| `-ngl` | (fixed `99`) | Layers offloaded to GPU for the main model. | `0`–`N` (99 = all layers on GPU when supported). |
| `-t` | `THREADS` / `-Threads` | CPU threads for non-GPU work (tokenization, sampling, etc.). | **Auto:** `-Threads 0` → e.g. **20** on 32 logical CPUs (Core i9-13900K). Manually try **12–24**; above **24** rarely helps and can hurt. |
| `-b` | `BATCH_SIZE` / `-Batch` | Physical batch size. | **512–8192**; **2048–4096** is a common sweep. |
| `-ub` | `UBATCH_SIZE` / `-UBatch` | Micro-batch; must be **≤** `-b`. | **256–2048**; often **half** of `-b` (e.g. 2048/1024, 4096/1024). |
| `--flash-attn` | (on) | Flash attention when the GPU/build supports it. | On unless debugging. |
| `--reasoning` | `REASONING` / `-Thinking` | Extended reasoning mode if supported. | `on` / `off`. |
| `--jinja` | (on) | Jinja chat templates (needed for Gemma and many instruct models). | Leave on for this stack. |
| `--metrics` | (on) | Metrics endpoint for monitoring. | On. |
| `-md`, `-ngld`, `--draft-min`, `--draft-max` | `-DraftModelFile`, `-DraftGpuLayers`, `-DraftMin`, `-DraftMax` | Speculative decoding: small draft model + verification on main model. | Draft **Q** smaller than main; **min** 2–8, **max** 8–32; **ngld** same idea as `-ngl`. |
| (extra) | `EXTRA_LLAMA_FLAGS` / `-ExtraFlags` | Pass-through for other `llama-server` flags. | Per `llama-server --help` for your image version. |

**Core i9-13900K (24P / 32 logical):** start with `-Threads 0` (auto → 20). In `.\benchmark.ps1`, compare **16**, **20**, **24** while holding `-Batch`/`-UBatch` fixed; keep the combo with best tok/s and stable latency.

---

## Configuration

- `docker-compose.yml` — LLM + usage-tracker services; comments above the `llm` service list llama.cpp flags and env vars
- `.env` — `MODEL_FILE`, `CONTEXT_SIZE`, `REASONING`, optional `THREADS`, `BATCH_SIZE`, `UBATCH_SIZE`, `SPECULATIVE_FLAGS`, `EXTRA_LLAMA_FLAGS`
- `.env.128k` — example env for 128k context
- `benchmark.py` / `analyze-benchmark.py` — load tests and analysis
- `run-benchmark.ps1` / `run-benchmark.sh` — benchmark helpers

---

## Docker Commands

```powershell
docker compose logs -f
docker ps
docker compose down
```

---

## File Layout

```
.env                  Environment / secrets (gitignored)
.env.128k             Example 128k context env
docker-compose.yml    Services (llm + usage-tracker)
Dockerfile            usage-tracker image
setup.ps1             One-time setup
run.ps1               Start / stop / restart server
test.ps1              Connectivity test
benchmark.ps1         Quick tokens/sec check
benchmark.py          Python benchmark suite
analyze-benchmark.py  Analyze benchmark JSON
usage_tracker.py      Proxy + usage logging
models/               Downloaded GGUFs (gitignored)
logs/                 Server logs
```

---

## License

Scripts: public domain. Model licenses: see each model card on Hugging Face (Qwen: Apache 2.0).
