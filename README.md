# llm-windows-server

Turn your idle Windows gaming rig into a low-latency, private LLM inference server. Your GPU's already doing nothing most of the time — put it to work.

## Why

Cloud LLMs are great — until you're sending hundreds of agentic round trips, hitting rate limits, or working with code you'd rather not leave your network. Meanwhile your RTX 4080 sits at 3% utilization between gaming sessions. This project bridges that gap: a Docker-based OpenAI-compatible API server that runs Qwen models entirely on your hardware. Any client on your network — MacBook, IDE, scripts — connects and gets instant, private inference.

The sweet spot is **agentic work**: tool calling, code generation, multi-step reasoning. These workloads compound latency with every round trip. Running locally means zero per-token cost, no rate limits, and your code never leaves your LAN.

## What You Get

- **OpenAI-compatible API** — works with Cursor, Continue, OpenCode, any OpenAI SDK client
- **Two models out of the box** — Qwen3.5-9B (90+ tok/s) and Qwen3.5-35B-A3B MoE (35+ tok/s)
- **Docker-based** — no CUDA toolkit, no cmake, no building from source
- **Health checks** — container auto-restarts on failure
- **Tailscale-ready** — secure remote access without touching your router

## Requirements

| Component | Minimum |
|-----------|---------|
| GPU | NVIDIA RTX 3060 12 GB |
| RAM | 32 GB |
| OS | Windows 10/11 |
| Docker Desktop | Latest with WSL2 backend |

If you have an NVIDIA GPU with 12+ GB VRAM and Docker Desktop installed, you're good. That's it.

---

## Step-by-Step Guide

### Step 1: Install Docker Desktop

If you don't have it yet, grab [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/). Make sure it's using the WSL2 backend (this is the default in recent versions).

Verify it's running:

```powershell
docker --version
docker info
```

You should see your GPU listed under the GPU section of `docker info`. If not, make sure your NVIDIA drivers are up to date.

### Step 2: Clone and Run Setup

```powershell
git clone <this-repo>
cd llm-windows-server
.\setup.ps1
```

Setup does the heavy lifting:

1. Verifies Docker Desktop can see your GPU
2. Pulls the `ghcr.io/ggml-org/llama.cpp:server-cuda` image
3. Downloads Qwen3.5-9B (~5 GB) and Qwen3.5-35B-A3B (~21 GB)
4. Creates a Windows firewall rule for port 8899

First run takes a few minutes while the models download. Subsequent runs are instant.

### Step 3: Start the Server

```powershell
.\run.ps1            # starts 9B model (fast, default)
.\run.ps1 -Model 35b # starts 35B model (smarter, slower)
```

That's it. Your server is now listening on `http://0.0.0.0:8899/v1`.

### Step 4: Verify It Works

```powershell
.\test.ps1
```

You should see a JSON response with a completion. If you want to test from another machine on your network:

```powershell
.\test.ps1 -Server 192.168.1.100   # use your Windows machine's IP
```

### Step 5: Check Your Numbers

```powershell
.\benchmark.ps1
```

This measures tokens per second so you know what to expect. Run it with `-Runs 5` for a more stable average.

### Step 6: Connect Your Clients

This is where it gets fun. Your server speaks the OpenAI API, so any client that supports OpenAI-compatible endpoints just works.

**From any machine on your network:**

```bash
export OPENAI_BASE_URL=http://<windows-ip>:8899/v1
```

**In OpenCode**, add the provider to `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama-at-home": {
      "name": "Llama.cpp (RTX4080)",
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

Replace `<windows-ip>` with your Windows machine's IP address (or Tailscale IP if you're connecting remotely). After restarting OpenCode, the local models appear in the model selector.

**In Cursor / Continue / any OpenAI SDK client**, set the base URL to `http://<windows-ip>:8899/v1` and you're done.

### Step 7 (Optional): Access Over Tailscale

If you want to use this server from outside your home network, Tailscale is the cleanest approach. No port forwarding, no exposing anything to the public internet.

1. Install [Tailscale](https://tailscale.com) on your Windows machine and log in
2. Install Tailscale on your client machine (MacBook, laptop, phone, whatever)
3. Both devices are now on the same virtual network
4. Use the Tailscale IP (starts with `100.x.x.x`) as your `<windows-ip>`

```powershell
# Find your Tailscale IP
tailscale ip -4
```

---

## Model Selection

| Model | Size | Speed | When to Use |
|-------|------|-------|-------------|
| Qwen3.5-9B | ~5 GB | 80+ t/s | Default. Fast agentic loops, code edits, chat |
| Qwen3.5-35B-A3B | ~21 GB | 35+ t/s | Complex reasoning, architecture, debugging |

The 35B model is MoE (Mixture of Experts) — 35B total parameters but only 3B activate per token. It's slower than 9B but punches well above its weight on harder tasks.

**Practical workflow:** run 9B by default. Switch to 35B when you hit a problem that needs deeper thinking. Switch back.

```powershell
.\run.ps1 -Model 35b -Restart   # switch to 35B
.\run.ps1 -Restart              # back to 9B
```

## Configuration

```powershell
.\run.ps1 -Context 16384   # smaller context window (saves VRAM)
.\run.ps1 -Thinking        # enable extended reasoning mode
```

## Docker Commands

```powershell
docker compose logs -f     # stream server logs
docker ps                  # check container status
docker compose down        # stop the server
```

## File Layout

```
.env                  HuggingFace token (gitignored)
docker-compose.yml    Container definition
setup.ps1             One-time setup (pulls image + models)
run.ps1               Start/stop/restart server
test.ps1              Test connectivity
benchmark.ps1         Measure tokens/second
models/               Downloaded models (gitignored)
```

## License

Scripts: public domain. Models: Apache 2.0 (Qwen).
