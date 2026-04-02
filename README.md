# llm-server

Run Qwen models locally on Windows with an NVIDIA GPU via Docker. Serve an OpenAI-compatible API to any client — your MacBook, IDE plugins, or scripts — over your LAN or Tailscale.

## Why

Cloud LLM APIs are slow, expensive, and log everything. A 4080 with 16 GB VRAM and 96 GB system RAM is idle most of the time. This project turns that idle hardware into a low-latency, private inference server that you own.

The primary workload is **agentic work** — tool calling, code generation, multi-step reasoning — where round-trip latency compounds and privacy matters. Running locally means zero per-token cost, no rate limits, and no data leaves your network.

## Features

- **OpenAI-compatible API** — works with Cursor, Continue, Claude Desktop, any OpenAI SDK client
- **Two models** — Qwen3.5-9B (90+ tok/s, 100% GPU) and Qwen3.5-35B-A3B (35+ tok/s, MoE)
- **Docker-based** — no build step, no CUDA toolkit, no cmake
- **Health checks** — container auto-restarts on failure
- **Tailscale-ready** — secure remote access without port forwarding

## Requirements

| Component | Minimum |
|-----------|---------|
| GPU | NVIDIA RTX 3060 12 GB |
| RAM | 32 GB |
| OS | Windows 10/11 |
| Docker Desktop | Latest with WSL2 backend |

## Quick Start

### 1. Install

```powershell
.\setup.ps1
```

This:
1. Verifies Docker Desktop + GPU access
2. Pulls the `ghcr.io/ggml-org/llama.cpp:server-cuda` image
3. Downloads Qwen3.5-9B (~5 GB) and Qwen3.5-35B-A3B (~21 GB)
4. Creates a firewall rule for port 8899

### 2. Run

```powershell
.\run.ps1                  # 9B model (fast)
.\run.ps1 -Model 35b       # 35B model (smarter)
.\run.ps1 -Stop            # Stop server
.\run.ps1 -Restart         # Restart
```

### 3. Test

```powershell
.\test.ps1                        # Test locally
.\test.ps1 -Server 192.168.1.100  # Test from another machine
```

### 4. Benchmark

```powershell
.\benchmark.ps1                   # Measure tokens/second
.\benchmark.ps1 -Runs 5           # More runs for accuracy
.\benchmark.ps1 -Tokens 500       # Longer generations
```

### 5. Connect from Mac

```bash
export OPENAI_BASE_URL=http://<windows-ip>:8899/v1
```

## Model Selection

| Model | Size | Speed | Use Case |
|-------|------|-------|----------|
| Qwen3.5-9B | ~5 GB | 80+ t/s | Fast agentic loops |
| Qwen3.5-35B-A3B | ~21 GB | 35+ t/s | Complex reasoning, code gen |

The 35B model is MoE — 35B params but only 3B activate per token.

### Which model when?

**Use 9B for regular work:**
- Code edits, refactors, quick fixes
- Tool calling and agentic loops (latency matters)
- Chat, Q&A, documentation
- Anything where speed > depth

**Use 35B for planning:**
- Architecture decisions, system design
- Complex multi-step reasoning
- Debugging tricky issues
- Code review, security analysis

A practical workflow: run 9B by default (`.\run.ps1`), switch to 35B (`.\run.ps1 -Model 35b -Restart`) when you need deeper thinking, then switch back.

## Configuration

```powershell
.\run.ps1 -Context 16384   # Smaller context (more VRAM headroom)
.\run.ps1 -Thinking        # Enable reasoning mode
```

## Docker Commands

```powershell
docker compose logs -f     # Stream logs
docker ps                  # Check status
docker compose down        # Stop
```

## File Layout

```
.env                  HuggingFace token (gitignored)
docker-compose.yml    Container definition
setup.ps1             One-time setup
run.ps1               Start/stop server
test.ps1              Test connectivity
benchmark.ps1         Measure throughput
models/               Downloaded models (gitignored)
```

## License

Scripts: Public domain. Models: Apache 2.0 (Qwen).
