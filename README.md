# LLM Server

Turn your idle Windows machine with an NVIDIA GPU into a low-latency, private LLM inference server. Docker-based OpenAI-compatible API with usage tracking and optional high-load benchmarking.

## Why

Cloud LLMs are great until you are sending hundreds of agentic round trips, hitting rate limits, or working with code you would rather not leave your network. This project runs Qwen models on your hardware behind an OpenAI-compatible endpoint. Any client on your network can connect for private inference.

The sweet spot is **agentic work**: tool calling, code generation, multi-step reasoning. Running locally means zero per-token cost, no rate limits, and your code stays on your LAN.

## What You Get

- **OpenAI-compatible API** — works with Cursor, Continue, OpenCode, any OpenAI SDK client
- **Usage tracking** — requests proxied through a tracker on port 8899 with persisted stats
- **Two models out of the box** — Qwen3.5-9B and Qwen3.5-35B-A3B MoE
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

### Step 3: Start the Server

```powershell
.\run.ps1            # 9B model (default)
.\run.ps1 -Model 35b # 35B model
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
| Qwen3.5-35B-A3B | ~21 GB | slower | Harder reasoning, architecture, debugging |

The 35B model is MoE — large total parameters but a smaller active set per token.

```powershell
.\run.ps1 -Model 35b -Restart
.\run.ps1 -Restart
```

### Run.ps1 Options

```powershell
.\run.ps1 -Context 16384   # smaller context (saves VRAM)
.\run.ps1 -Thinking       # extended reasoning mode
.\run.ps1 -Stop           # stop stack
```

---

## Configuration

- `docker-compose.yml` — LLM + usage-tracker services
- `.env` — `MODEL_FILE`, `CONTEXT_SIZE`, `REASONING`, etc.
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

Scripts: public domain. Models: Apache 2.0 (Qwen).
