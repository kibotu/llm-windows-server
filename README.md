# llm-server

Run Qwen models locally on Windows with an NVIDIA GPU. Serve an OpenAI-compatible API to any client — your MacBook, IDE plugins, or scripts — over your LAN or Tailscale.

## Why

Cloud LLM APIs are slow, expensive, and log everything. A 4080 with 16 GB VRAM and 96 GB system RAM is idle most of the time. This project turns that idle hardware into a low-latency, private inference server that you own.

The primary workload is **agentic work** — tool calling, code generation, multi-step reasoning — where round-trip latency compounds and privacy matters. Running locally means zero per-token cost, no rate limits, and no data leaves your network.

## Features

- **OpenAI-compatible API** — works with Cursor, Continue, Claude Desktop, any OpenAI SDK client
- **Two models out of the box** — Qwen3.5-9B (90+ tok/s, 100% GPU) and Qwen3.5-35B-A3B (35+ tok/s, MoE)
- **Idempotent scripts** — `setup.ps1` and `run.ps1` are safe to run repeatedly; completed steps are skipped
- **Port hygiene** — kills stale processes, frees port 8899, health-checks before declaring ready
- **KV cache quantization** — Q8 KV cache halves context memory with zero quality loss
- **No thinking mode** — disabled by default to save tokens on simple agentic calls
- **Tailscale-ready** — secure remote access from anywhere without port forwarding
- **Apache 2.0 models** — no licensing restrictions

## Requirements

| Component | Minimum | This Setup |
|-----------|---------|------------|
| GPU | NVIDIA RTX 3060 12 GB | RTX 4080 16 GB |
| RAM | 32 GB | 96 GB |
| OS | Windows 10/11 | Windows 11 |
| Disk | 30 GB free (models + build) | — |
| CUDA | 11.8 | 12.6 (auto-upgraded) |
| PowerShell | 5.1 | 5.1 |

The setup script installs missing prerequisites via winget: CMake, Git, Git LFS, Python 3.12, CUDA 12.6.

## Quick Start

### Install

Run PowerShell **as Administrator**:

```powershell
.\setup.ps1
```

This does everything:

1. Installs CMake, Git LFS, Python 3.12 via winget
2. Upgrades CUDA to 12.6 if you're on 11.x
3. Clones and builds llama.cpp with CUDA support
4. Downloads Qwen3.5-9B Q4_K_M (~9 GB) and Qwen3.5-35B-A3B UD-Q4_K_XL (~19 GB)
5. Creates a Windows Firewall rule for port 8899

Safe to re-run. Each step checks for existing artifacts and skips what's done.

### Run

```powershell
.\run.ps1                  # 9B model — 90+ tok/s, 100% GPU
.\run.ps1 -Model 35b       # 35B MoE — 35+ tok/s, partial GPU offload
.\run.ps1 -Restart         # kill old, start fresh
.\run.ps1 -Context 16384   # smaller context, more VRAM headroom
```

The server binds to `0.0.0.0:8899`. The script prints your LAN IP and waits for the health endpoint before declaring ready.

### Connect from MacBook

On your local network:

```bash
export OPENAI_BASE_URL=http://<windows-pc-ip>:8899/v1
```

Over Tailscale (install on both machines):

```bash
export OPENAI_BASE_URL=http://<tailscale-ip>:8899/v1
```

Any tool that accepts an OpenAI base URL works. The API key field accepts any string — no auth by default.

## Architecture

```
MacBook ──(LAN/Tailscale)──► Windows PC :8899 ──► llama-server ──► CUDA GPU
                                                                    │
                                                       Qwen3.5-9B  │ 100% VRAM
                                                       Qwen3.5-35B │ ~70% VRAM + RAM offload
```

**llama.cpp** is the serving engine. It was chosen over Ollama and vLLM for three reasons:

1. **Speed on CPU offload** — benchmarks show Ollama is 3–10× slower when models exceed VRAM. llama.cpp's layer offloading is significantly more efficient.
2. **Tool calling reliability** — Ollama's multi-turn tool calling with Qwen3.5 is broken. llama.cpp handles it correctly.
3. **Windows support** — vLLM requires Linux/WSL. llama.cpp builds natively.

**Port 8899** is non-default to avoid collisions with common services (8080, 3000, 11434). The setup script creates a firewall rule automatically.

## Model Selection

| Model | Params | Active/Token | Quant | Size | Speed | Use Case |
|-------|--------|-------------|-------|------|-------|----------|
| Qwen3.5-9B | 9B | 9B | Q4_K_M | ~9 GB | 90+ t/s | Fast agentic loops, classification, routing |
| Qwen3.5-35B-A3B | 35B | 3B (MoE) | UD-Q4_K_XL | ~19 GB | 35+ t/s | Tool calling, code generation, reasoning |

The 35B model is a **Mixture of Experts** — 35B total parameters loaded, but only 3B activate per token. This means you get near-35B quality at near-3B compute cost. It is the recommended default for agentic work.

## Configuration

### Thinking Mode

Qwen3.5 defaults to generating `<think>` blocks before answering. This is useful for complex reasoning but wastes tokens on simple calls. Thinking is **disabled by default** via `--chat-template-kwargs '{"enable_thinking": false}'`.

To re-enable, run with `.\run.ps1 -NoThinking:$false`.

### Context Window

Default is 32K tokens. Reduce to 16K or 8K if you need more VRAM headroom or faster prompt processing:

```powershell
.\run.ps1 -Context 16384
```

### Switching Models at Runtime

Stop the current server (Ctrl+C) and restart with a different model flag. The script handles cleanup automatically — no manual process killing needed.

## Troubleshooting

**Build fails**: Delete `llama.cpp\build` and re-run `.\setup.ps1`. The build step will retry.

**Port 8899 in use**: `.\run.ps1` kills whatever is holding the port automatically. If it persists, check for another service: `Get-NetTCPConnection -LocalPort 8899`.

**Server won't start**: Check `logs\server.log` for CUDA or model loading errors. Most failures are missing CUDA DLLs — ensure you opened a new PowerShell window after CUDA installation.

**Model download fails**: Verify your HF token in `.env`. The token is read from `.env` at runtime, not baked into scripts.

**Slow inference on 35B model**: This is expected with partial CPU offload. The 9B model runs 100% on GPU at 90+ t/s. Use the 35B model when quality matters more than latency.

## File Layout

```
.env                          HuggingFace token (gitignored)
.gitignore
setup.ps1                     One-time idempotent setup
run.ps1                       Start/restart server
logs/
  server.log                  Server output
models/
  *Q4_K_M.gguf                Qwen3.5-9B
  *Q4_K_XL.gguf               Qwen3.5-35B-A3B
llama.cpp/                    Cloned and built by setup.ps1
```

## License

Scripts are public domain. Models are Apache 2.0 (Qwen).
