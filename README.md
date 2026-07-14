# LLM Server

[![Medium](https://img.shields.io/badge/Medium-@kibotu-000000?style=flat-square&logo=medium&logoColor=white)](https://medium.com/@kibotu/two-paths-to-local-llm-servers-windows-nvidia-vs-mac-apple-silicon-1e28d606f600?sk=a5d9989d124d7f9b844927f0f545ed09)

Turn an idle Windows + NVIDIA machine into a private, OpenAI-compatible LLM server.
Two scripts, one Docker command, sensible defaults for **Qwen3.6-35B-A3B** with vision.

## Quick start

```powershell
.\setup.ps1     # install Docker + hf CLI, generate API key, pull image, download model
.\run.ps1       # start the server (stays in the foreground, streams logs)
```

API endpoint: `http://localhost:8899/v1`

`setup.ps1` generates a random **API key** into `.env` (`LLAMA_API_KEY`). Clients
must send it as `Authorization: Bearer <key>`. `run.ps1` prints the key on startup.

Put your Hugging Face token in `.env` first (copy `.env.example` to `.env`).

---

## Two scripts, that's it

| Script | What it does |
|--------|--------------|
| `setup.ps1` | **Setup + update in one.** Installs Docker Desktop, verifies GPU access, installs the latest Hugging Face CLI, pulls the latest llama.cpp image, rebuilds the usage-tracker proxy, downloads the model, opens the firewall, prunes old Docker layers. Idempotent — re-run it to update. |
| `run.ps1` | **Start / reconcile / stop.** Starts the server with your chosen settings and streams logs. Re-run any time to change settings on the live server. `-Stop` tears it down. |

The project is deliberately minimal — just these two scripts plus the Compose stack.

---

## Models

| Alias | Model | Size | Vision | Notes |
|-------|-------|------|--------|-------|
| `qwen36` | Qwen3.6-35B-A3B IQ4_XS | ~17 GB | Yes | **Default.** MoE, experts offloaded to RAM. |
| `qwen35-9b` | Qwen3.5-9B Q4_K_M | ~5 GB | Yes | Lighter, dense, faster. |

Both are downloaded on demand into `.\models\` (gitignored). Switch with `-Model`:

```powershell
.\run.ps1 -Model qwen35-9b
```

---

## `run.ps1`

```powershell
.\run.ps1 [options]
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Model` | `qwen36` | `qwen36` or `qwen35-9b` |
| `-Context` | `262144` | Total KV context tokens |
| `-Parallel` | `1` | Concurrent request slots (context is split across them) |
| `-Thinking` | `$true` | Extended reasoning / `<think>` blocks |
| `-Vision` | auto | Enable the vision projector (on when the mmproj file exists) |
| `-Threads` | `0` (auto) | CPU threads (auto: 20 on 32-core, 12 on 16-core) |
| `-Batch` / `-UBatch` | `2048` | Batch sizes (auto-raised to 4096 for MoE) |
| `-KvCache` | `q8_0` | `q4_0` (save VRAM), `q8_0` (balanced), `f16` (best) |
| `-MoeOffload` | `auto` | `auto`/`all` = experts to CPU, `off` = full GPU, `N` = first N layers |
| `-ExtraFlags` | – | Passed verbatim to `llama-server` |
| `-NoDownload` | – | Fail instead of auto-downloading a missing model |
| `-Stop` | – | Stop the server |

```powershell
.\run.ps1                             # default: Qwen3.6 35B, vision + reasoning
.\run.ps1 -Context 65536 -Parallel 4  # 4 slots, shorter context (reconciles live)
.\run.ps1 -KvCache q4_0               # save VRAM
.\run.ps1 -Thinking:$false            # disable reasoning
.\run.ps1 -Stop                       # stop
```

Re-running `run.ps1` is safe: Docker Compose recreates the container only when the
config actually changes. Ctrl+C stops log streaming; the server keeps running.

---

## `setup.ps1`

```powershell
.\setup.ps1 [-Model qwen36|qwen35-9b] [-SkipModel] [-Clean]
```

| Parameter | Description |
|-----------|-------------|
| `-Model` | Which model to download (default `qwen36`) |
| `-SkipModel` | Refresh Docker + tooling only, skip the model download |
| `-Clean` | Aggressive cleanup: remove all unused images, not just dangling layers |

```powershell
.\setup.ps1                  # full setup / update
.\setup.ps1 -SkipModel       # update image + proxy only
.\setup.ps1 -Clean           # update and reclaim disk
```

The model download uses the `hf` CLI and reads `HF_TOKEN` from `.env`.

---

## How it works

```
client ──▶ usage-tracker (:8899) ──▶ llama.cpp server (:8888, GPU)
                 │
                 └─ records token usage to usage_data.json
```

- **`docker-compose.yml`** is the single source of truth for defaults and the image tag.
  `run.ps1` sets environment variables that the compose `command:` consumes.
- **MoE expert offloading** (`--cpu-moe`) keeps attention on the GPU while routed
  experts live in DDR5 RAM, so a 35B MoE model runs comfortably on 16 GB VRAM.

### VRAM budget (Qwen3.6 IQ4_XS, q8_0 KV, RTX 4080 16 GB)

| Component | GPU |
|-----------|-----|
| Model weights (attention + shared) | ~13–14 GB |
| KV cache | ~1–1.5 GB |
| CUDA overhead | ~0.5 GB |
| **Total** | **~15 GB** (routed experts sit in ~6–7 GB of RAM) |

---

## Tuning reference

Every flag `run.ps1` passes to `llama-server` (via `docker-compose.yml`), what it
does, and why it's set the way it is. Values in **bold** are the defaults here.

### Model & context

| Flag | Default | What it does |
|------|---------|--------------|
| `-m` | Qwen3.6 IQ4_XS | Path to the GGUF model file inside the container (`/models/…`). |
| `--mmproj` | auto | Vision projector (multimodal). Enabled when the mmproj file exists; turn off with `-Vision:$false`. |
| `-c` | **262144** | Total KV context window in tokens. Split evenly across `--parallel` slots. Lower it to reclaim VRAM. |
| `-ngl` | **99** | Number of model layers offloaded to the GPU. 99 = "all of them"; the GPU runs attention + shared FFN. |

### KV cache

| Flag | Default | What it does |
|------|---------|--------------|
| `-ctk` | **q8_0** | Key-cache quantization. `q8_0` halves VRAM vs `f16` with negligible quality loss. `q4_0` halves it again for long context. |
| `-ctv` | **q8_0** | Value-cache quantization. Kept equal to `-ctk`. |
| `--flash-attn` | **on** | Fused flash-attention kernels: ~30% less attention VRAM and faster on Ada/Ampere GPUs. |

### Throughput & batching

| Flag | Default | What it does |
|------|---------|--------------|
| `-b` | **2048** (4096 MoE) | Physical batch size — how many prompt tokens are processed per forward pass. Higher = faster prompt ingestion. |
| `-ub` | **2048** (4096 MoE) | Micro-batch size. **Must equal `-b` for MoE models**, or throughput tanks. |
| `-t` | **auto** | CPU threads for expert compute + sampling. Auto-picks by core count (20 on 32-core, 12 on 16-core). |
| `--parallel` | **1** | Concurrent request slots. Each slot gets `context / parallel` tokens. Raise for multi-client serving. |
| `--cont-batching` | **on** | Continuous batching. Without it, only one request runs at a time even with multiple slots. |

### MoE expert offloading

| Flag | Default | What it does |
|------|---------|--------------|
| `--cpu-moe` | **on** (MoE) | Keep routed experts in system RAM, attention on the GPU. This is what lets a 35B MoE model fit in 16 GB VRAM. |
| `--n-cpu-moe N` | – | Offload only the first `N` layers' experts to CPU (fine-grained VRAM/speed trade-off via `-MoeOffload N`). |

### Behavior & serving

| Flag | Default | What it does |
|------|---------|--------------|
| `--reasoning` | **on** | Qwen3 extended thinking / `<think>` blocks. Turn off for faster, terser answers. |
| `--jinja` | **on** | Use the model's built-in Jinja chat template. Required for correct Qwen3.x prompting and tool calling. |
| `--metrics` | **on** | Expose Prometheus-style metrics at `/metrics`. |
| `--host` / `--port` | `0.0.0.0` / `8888` | Bind address inside the container. Clients reach it through the proxy on `8899`. |

### Memory stability (Windows/WSL2)

| Flag | Default | What it does |
|------|---------|--------------|
| `--no-mmap` | **on** | Disable memory-mapped model loading. Slower cold start, but avoids Windows page-cache eviction stalling inference mid-request. |
| `--mlock` | **on** | Lock model + KV cache into RAM so the OS never swaps them to the page file. |
| `--numa distribute` | **on** | Spread threads/memory across NUMA nodes. Helps on multi-socket boxes, harmless on single-socket. |

### Optional extras (not on by default)

Not set by `run.ps1`, but useful in specific cases — pass them via `-ExtraFlags`.

| Flag | Try when | What it does |
|------|----------|--------------|
| `--cache-reuse 256` | You reuse a long, fixed system prompt | Reuses cached KV for the shared prefix, skipping its prefill on every request. |
| `--defrag-thold 0.1` | Long-running server, many short requests | Defragments the KV cache once it's >10% fragmented, reclaiming slot space. |
| `--slot-save-path /logs` | Clients reconnect often | Persists per-slot state to disk so a session can resume without re-prefilling. |
| `--threads-batch N` | Prompt ingestion is CPU-bound | Uses a separate (usually higher) thread count for batch/prefill vs generation. |
| `-ctk q4_0 -ctv q4_0` | You hit VRAM limits at long context | Halves KV-cache VRAM again beyond `q8_0` (use `-KvCache q4_0` for this directly). |

> **Overriding flags:** anything not exposed as a `run.ps1` parameter can be passed
> through with `-ExtraFlags`, e.g. `.\run.ps1 -ExtraFlags "--cache-reuse 256 --defrag-thold 0.1"`.

---

## Client configuration

Base URL: `http://<host-ip>:8899/v1`
API key: the `LLAMA_API_KEY` value from your `.env` (sent as `Authorization: Bearer <key>`).

Works with Cursor, Continue, the OpenAI SDK, and any OpenAI-compatible client.
For secure remote access, install [Tailscale](https://tailscale.com) and use the
Tailscale IP (`tailscale ip -4`).

### Authentication

The usage-tracker proxy validates every request against `LLAMA_API_KEY` (generated
by `setup.ps1` into `.env`). Requests without a matching `Authorization: Bearer <key>`
header get a `401`. `/health` stays open so probes keep working. Leaving
`LLAMA_API_KEY` blank disables auth entirely (open server).

```bash
curl http://<host-ip>:8899/v1/models -H "Authorization: Bearer <your-key>"
```

### OpenCode (e.g. from a Mac)

A ready-to-use config ships in [`opencode/opencode.json`](opencode/opencode.json).
It exposes both models and points at the server through the usage-tracker proxy.

1. Copy it into place on the client:

   ```bash
   mkdir -p ~/.config/opencode
   cp opencode/opencode.json ~/.config/opencode/opencode.json
   ```

2. Set the `baseURL` and `apiKey`:

   - **baseURL** — how to reach the server:
     - **Same machine (Windows host):** leave it as `http://127.0.0.1:8899/v1`.
     - **From a Mac / another device on the LAN:** use the host's IP, e.g.
       `http://192.168.1.50:8899/v1` (the `run.ps1` banner prints the LAN URL).
     - **Over Tailscale:** use the host's Tailscale IP, e.g. `http://100.x.y.z:8899/v1`.
   - **apiKey** — replace the placeholder with your `LLAMA_API_KEY` from `.env`
     (the `run.ps1` banner prints it too).

   ```jsonc
   "options": {
     "baseURL": "http://<host-ip>:8899/v1",
     "apiKey": "sk-...your LLAMA_API_KEY from .env..."
   }
   ```

3. Start OpenCode — it defaults to `llama-at-home/qwen36-35b`. Switch models with
   the model picker, or edit the `"model"` field.

> The shipped config uses a placeholder api key
> (`sk-REPLACE-WITH-LLAMA_API_KEY-FROM-DOTENV`) — swap in your real key. It also
> sets sensible context limits, auto-compaction, and tool permissions; trim the
> `permission` / `mcp` blocks to taste, they're just a demo.

---

## Requirements

| Component | Minimum |
|-----------|---------|
| GPU | NVIDIA RTX 3060 12 GB (RTX 4080 16 GB recommended) |
| RAM | 32 GB (96 GB recommended for MoE offload) |
| OS | Windows 10/11 |
| Docker | Desktop with WSL2 backend |
| Python | 3.x (for the Hugging Face CLI) |

---

## Files

```
setup.ps1           Setup + update (Docker, GPU, hf CLI, model, firewall, cleanup)
run.ps1             Start / reconcile / stop the server
docker-compose.yml  Service definitions (parameterized, env-var driven)
Dockerfile          usage-tracker proxy image
usage_tracker.py    Token-usage proxy
.env.example        Template — copy to .env and add your HF_TOKEN
opencode/           Ready-to-use OpenCode client config (opencode.json)
models/             Downloaded GGUFs (gitignored)
```

---

## License

Scripts: public domain. Models: see their respective Hugging Face model cards.
