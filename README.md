# LLM Server

[![Medium](https://img.shields.io/badge/Medium-@kibotu-000000?style=flat-square&logo=medium&logoColor=white)](https://medium.com/@kibotu/two-paths-to-local-llm-servers-windows-nvidia-vs-mac-apple-silicon-1e28d606f600?sk=a5d9989d124d7f9b844927f0f545ed09)

Turn an idle Windows + NVIDIA machine into a private, OpenAI-compatible LLM server.
Two scripts, one Docker command, sensible defaults for **Qwen3.6-35B-A3B** with vision.

## Quick start

```powershell
.\setup.ps1     # verify prereqs, install Docker + hf CLI, generate API key, pull image, download model
.\run.ps1       # start the server (stays in the foreground, streams logs)
```

`setup.ps1` checks for Docker, Python, uv, and Git upfront. If Docker isn't
installed, it auto-elevates to Administrator and installs it via winget. Model
GGUF files are downloaded to the Hugging Face cache and symlinked into `.\models\`
(Developer Mode or Administrator required for symlinks; otherwise files are copied).

Before the first run, copy `.env.example` to `.env` and add your Hugging Face token.
`setup.ps1` then generates a random `LLAMA_API_KEY` into `.env`, and `run.ps1` prints
both the endpoint and the key on startup.

That's it — the server is now serving an OpenAI-compatible API at `http://localhost:8899/v1`.

## Connect a client

- **Base URL:** `http://<host-ip>:8899/v1`
- **API key:** the `LLAMA_API_KEY` from `.env`, sent as `Authorization: Bearer <key>`

Every request is validated against `LLAMA_API_KEY` by the gateway proxy; a
missing or wrong key gets a `401` (only `/health` stays open). Leaving the key blank
disables auth entirely. Quick check:

```bash
curl http://<host-ip>:8899/v1/models -H "Authorization: Bearer <your-key>"
```

Works with Cursor, Continue, the OpenAI SDK, and any OpenAI-compatible client. For
`<host-ip>`, use `127.0.0.1` on the same machine, the LAN IP from another device, or
a [Tailscale](https://tailscale.com) IP (`tailscale ip -4`) for secure remote access.

### OpenCode

A ready-to-use config ships in [`opencode/opencode.json`](opencode/opencode.json). It
exposes both models and points at the server through the proxy.

1. Copy it into place on the client:

   ```bash
   mkdir -p ~/.config/opencode
   cp opencode/opencode.json ~/.config/opencode/opencode.json
   ```

2. Set `baseURL` to your endpoint and `apiKey` to your key (both printed by the
   `run.ps1` banner):

   ```jsonc
   "options": {
     "baseURL": "http://<host-ip>:8899/v1",
     "apiKey": "sk-...your LLAMA_API_KEY from .env..."
   }
   ```

3. Start OpenCode — it defaults to `llama-at-home/big`. Pick any of the four models
   in the selector (`big`, `small`, `heretic`, `tiny`) or set `"model"` to
   `llama-at-home/<alias>`. Only one GGUF is loaded at a time on the server; use
   the MCP `switch_model` tool (below) to reload before switching.

The shipped config also sets sensible context limits, auto-compaction, and tool
permissions; trim the `permission` / `mcp` blocks to taste — they're just a demo.

| OpenCode alias | Server alias | GGUF |
|----------------|--------------|------|
| `big` | `qwen36` | `Qwen3.6-35B-A3B-UD-IQ4_XS.gguf` |
| `small` | `qwen35-9b` | `Qwen3.5-9B-Q4_K_M.gguf` |
| `heretic` | `heretic` | `Qwen3.6-35B-A3B-Heretic-Cerebellum-14GB.gguf` |
| `tiny` | `qwen35-4b` | `Qwen_Qwen3.5-4B-Q4_K_M.gguf` |

#### MCP (model switching)

OpenCode can call the llm-server MCP tools over HTTP so the agent can list models,
check status, and switch the loaded GGUF without leaving the chat. Add this to the
`mcp` block in `~/.config/opencode/opencode.json` (or merge into
[`opencode/opencode.json`](opencode/opencode.json) before copying):

```jsonc
"mcp": {
  "llm-server": {
    "type": "http",
    "url": "http://<host-ip>:8899/mcp",
    "enabled": true,
    "headers": {
      "Authorization": "Bearer <LLAMA_ADMIN_KEY>"
    },
    "timeout": 660000
  }
}
```

Use `type: "http"` for Streamable HTTP (what this server speaks). `type: "remote"`
is the older SSE alias and will not work here. Set `timeout` high enough for
`switch_model` (model reload can take several minutes).

- **Same machine:** `http://127.0.0.1:8899/mcp`
- **Remote client:** your LAN/Tailscale/WAN IP, same port as inference
- **Auth:** `LLAMA_ADMIN_KEY` from `.env` (falls back to `LLAMA_API_KEY`)

Tools exposed: `list_tools`, `list_models`, `get_server_status`, `switch_model`,
`start_server`, `stop_server`. Ask the agent e.g. *"switch to the tiny model"* —
it calls `switch_model("qwen35-4b")`, which reloads the container via `run.ps1`
and waits until ready.

The server must be running (`.\run.ps1`) so the gateway proxy and host MCP
server are up. Quick check from the client machine:

```powershell
.\scripts\test-mcp-list-models.ps1          # on the Windows host
.\scripts\switch-mcp-to-small.ps1 -Wait   # switch via MCP (big/small/heretic)
```

Or from any machine with curl, see the MCP section below.

## Remote model switching (MCP-only)

The server loads **one model at a time**. All admin operations (status, models,
switch, start, stop) are exposed exclusively via MCP tools on `:8899/mcp`:

```bash
# Quick health check from any machine with curl
curl http://<host-ip>:8899/health
```

Architecture:

```
client ──▶ gateway :8899 /mcp ──▶ mcp/server.py :8901 ──▶ host_controller.py :8900
                                                                    │
                                                                    └── run.ps1 -NoFollow -Model …
```

`host_controller.py` runs on the Windows host (auto-started by `run.ps1`). It
cancels any in-flight reconcile and starts a new one. A new reconcile recreates
the llama container with the requested GGUF.

### MCP (Cursor / agents)

The MCP server speaks **Streamable HTTP** (JSON-RPC over HTTP), not stdio. Clients
connect with a **URL** — no repo clone, no local Python process. It runs on the
Windows host (`127.0.0.1:8901`) and is reverse-proxied at `:8899/mcp`, so remote
clients use the **same WAN port and bearer key** as inference:

```
client ──▶ gateway :8899 /mcp ──▶ mcp/server.py :8901 (Windows host)
                                               │
                                               └── host_controller.py :8900 /admin/*
```

`run.ps1` auto-starts `mcp/server.py` (alongside `host_controller.py`). One-time
dependency install on the host:

```powershell
uv pip install -r mcp/requirements.txt
```

Configure any client with a URL + bearer header (see `mcp/cursor-mcp.example.json`):

**Cursor** (`mcp/cursor-mcp.example.json`):

```json
{
  "mcpServers": {
    "llm-server": {
      "url": "http://<host-ip>:8899/mcp",
      "headers": {
        "Authorization": "Bearer <LLAMA_ADMIN_KEY>"
      }
    }
  }
}
```

**Hermes** (`~/.hermes/config.yaml`):

```yaml
mcp_servers:
  kira:
    url: http://<host-ip>:8899/mcp
    headers:
      Authorization: Bearer <LLAMA_ADMIN_KEY>
      Accept: application/json, text/event-stream
    timeout: 660
    tools:
      include:
        - list_tools
        - list_models
        - get_server_status
        - switch_model
        - start_server
        - stop_server
      prompts: false
      resources: false
```

#### Available tools

| Tool | Description |
|------|-------------|
| `list_tools` | List all available MCP tools with descriptions |
| `list_models` | List switchable model aliases (qwen36, heretic, qwen35-9b, qwen35-4b) |
| `get_server_status` | Current model, runtime state, job status, llama.cpp health |
| `switch_model` | Switch the loaded GGUF model (params: `model`, `context`, `thinking`, `wait`, `cancel`) |
| `start_server` | Start the stack — docker compose up (params: `model`, `context`) |
| `stop_server` | Stop the stack — docker compose down |

`/mcp` is gated by the admin key (it can run `run.ps1`), so treat it like `/admin/*`.
On a remote box (Pi, laptop), use the host's WAN/Tailscale/LAN IP. After a
`switch_model`, tell Hermes `/sync` (or `/model big`/`/model small`) to match.

> **Local-only stdio** is still available for a client on the same machine: set
> `MCP_TRANSPORT=stdio` and launch `mcp/server.py` as a `command`/`args` server.

### Shell scripts (Windows)

Reads `LLAMA_API_KEY` / `LLAMA_ADMIN_KEY` from the repo `.env` automatically.

```powershell
.\scripts\llm-status.ps1          # current model
.\scripts\switch-to-9b.ps1        # switch to Qwen3.5-9B (returns immediately)
.\scripts\switch-to-35b.ps1       # switch to Qwen3.6-35B (returns immediately)
.\scripts\switch-to-heretic.ps1   # switch to Heretic Cerebellum 14GB (returns immediately)
.\scripts\switch-to-4b.ps1          # switch to Qwen3.5-4B (returns immediately)
.\scripts\llm-status.ps1 -Json    # raw admin/status JSON

# MCP (Streamable HTTP via :8899/mcp):
.\scripts\test-mcp-list-models.ps1
.\scripts\switch-mcp-to-big.ps1
.\scripts\switch-mcp-to-small.ps1
.\scripts\switch-mcp-to-heretic.ps1
.\scripts\switch-mcp-to-tiny.ps1

# Block until the reload finishes (can take several minutes):
.\scripts\switch-to-9b.ps1 -Wait
.\scripts\switch-to-heretic.ps1 -Wait
.\scripts\switch-to-4b.ps1 -Wait
.\scripts\switch-mcp-to-small.ps1 -Wait
.\scripts\switch-mcp-to-tiny.ps1 -Wait
```

These call the same `/admin/*` API as the MCP server (REST scripts) or the MCP
`switch_model` tool directly (MCP scripts). The server must be running (`.\run.ps1`)
so `host_controller.py` and `mcp/server.py` are available.

## Models

| Alias | Model | Size | Vision | Notes |
|-------|-------|------|--------|-------|
| `qwen36` | Qwen3.6-35B-A3B IQ4_XS | ~17 GB | Yes | **Default.** MoE, experts offloaded to RAM. |
| `heretic` | [Qwen3.6-35B-A3B Heretic Cerebellum 14GB](https://huggingface.co/deucebucket/Qwen3.6-35B-A3B-Heretic-Cerebellum-GGUF) | ~14.5 GB | Yes | MoE Cerebellum quant; uses its own mmproj. |
| `qwen35-9b` | Qwen3.5-9B Q4_K_M | ~5 GB | Yes | Lighter, dense, faster. |
| `qwen35-4b` | [Qwen3.5-4B Q4_K_M](https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF) | ~3 GB | Yes | Tiny, dense, fastest. |

Models download on demand into `.\models\` (gitignored). Files are stored in the
Hugging Face cache and symlinked to avoid duplication (copy fallback if symlinks
aren't available). Switch with `-Model`:

```powershell
.\run.ps1 -Model heretic
.\run.ps1 -Model qwen35-9b
.\run.ps1 -Model qwen35-4b
```

## The two scripts

The whole project is two PowerShell scripts plus the Compose stack — nothing else to learn.

### `run.ps1` — start, reconcile, stop

```powershell
.\run.ps1 [options]
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Model` | `qwen36` | `qwen36`, `heretic`, `qwen35-9b`, or `qwen35-4b` |
| `-Context` | per-model | Total KV context tokens (262144 for 35B, 128000 for 9B, 96000 for 4B) |
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

Re-running is safe: Docker Compose recreates the container only when the config
actually changes. Ctrl+C stops log streaming; the server keeps running.

For unattended operation, use the watchdog wrapper — it restarts `run.ps1` on
crash, health failure, or container exit:

```powershell
.\run-watchdog.ps1                          # default model, unlimited retries
.\run-watchdog.ps1 -Model qwen35-4b         # tiny model with auto-restart
.\run-watchdog.ps1 -Delay 30 -MaxRetries 5  # give up after 5 consecutive failures
```

### `setup.ps1` — setup + update in one

Verifies prerequisites, installs Docker Desktop (auto-elevating if needed),
verifies GPU access, installs the latest `hf` CLI via `uv`, pulls the latest
llama.cpp image, rebuilds the gateway proxy, downloads the model (via the `hf`
CLI reading `HF_TOKEN` from `.env`), opens the firewall, and prunes old Docker
layers. Idempotent — re-run it to update.

```powershell
.\setup.ps1 [-Model qwen36|heretic|qwen35-9b|qwen35-4b] [-SkipModel] [-Clean]
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

#### Elevation & Developer Mode

`setup.ps1` adapts to your privilege level:

| Scenario | What happens |
|----------|-------------|
| Docker missing, not admin | Auto re-launches as Administrator (UAC prompt) |
| Docker present, not admin | Runs normally; firewall rule skipped with manual `netsh` command |
| `mklink` + Developer Mode | Symlinks work without elevation |
| `mklink` + admin | Symlinks work |
| `mklink` neither | Falls back to file copy (uses more disk) |

Enable **Developer Mode** for seamless symlinks without elevation:
Settings > System > For developers > Developer Mode.

## How it works

```
client ──▶ gateway (:8899) ──▶ llama.cpp server (:8888, GPU)
                 │
                 ├─ requests.jsonl      append-only request log (survives restarts)
                 └─ daily_summary.json  per-day + per-client aggregates
```

- **`docker-compose.yml`** is the single source of truth for defaults and the image
  tag. `run.ps1` sets environment variables that the compose `command:` consumes.
- **MoE expert offloading** (`--cpu-moe`) keeps attention on the GPU while routed
  experts live in DDR5 RAM, so a 35B MoE model runs comfortably on 16 GB VRAM.

### VRAM budget (Qwen3.6 IQ4_XS, q8_0 KV, RTX 4080 16 GB)

| Component | GPU |
|-----------|-----|
| Model weights (attention + shared) | ~13–14 GB |
| KV cache | ~1–1.5 GB |
| CUDA overhead | ~0.5 GB |
| **Total** | **~15 GB** (routed experts sit in ~6–7 GB of RAM) |

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
These reduce **latency** (time-to-first-token) or VRAM; none of them raise raw
tokens/s (see the next section for that).

| Flag | Try when | What it does |
|------|----------|--------------|
| `--cache-reuse 256` | RAG / dynamic content mid-prompt | Reuses cached KV chunks even when the shared text isn't a pure prefix. Caveats: if the model runs SWA layers it also needs `--swa-full` (big VRAM cost at long context), and on Qwen3.5/3.6-arch GGUFs the checkpoint cache is reported inert — so test before relying on it. |
| `--defrag-thold 0.1` | Long-running server, many short requests | Defragments the KV cache once it's >10% fragmented, reclaiming slot space. |
| `--slot-save-path /logs` | Clients reconnect often | Persists per-slot state to disk so a session can resume without re-prefilling. |
| `--threads-batch N` | Prompt ingestion is CPU-bound | Uses a separate (usually higher) thread count for batch/prefill vs generation. |
| `-ctk q4_0 -ctv q4_0` | You hit VRAM limits at long context | Halves KV-cache VRAM again beyond `q8_0` (use `-KvCache q4_0` for this directly). |

> **Overriding flags:** anything not exposed as a `run.ps1` parameter can be passed
> through with `-ExtraFlags`, e.g. `.\run.ps1 -ExtraFlags "--cache-reuse 256 --swa-full"`.

### Improving tokens/s (MoE + `--cpu-moe`)

With experts offloaded to RAM, **generation speed is capped by DDR5 memory
bandwidth** — every token streams the active expert weights from system RAM.
That makes the effective levers different from a fully-on-GPU model:

1. **Sweep `--n-cpu-moe` and benchmark — the #1 knob.** Counter-intuitively,
   *all experts on CPU* (the default `--cpu-moe`) is usually fastest on 12–16 GB
   cards; moving experts back onto the GPU tends to make generation **slower**.
   Confirm on your hardware:

   ```powershell
   docker exec -it llm-server llama-bench -m /models/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf -ngl 99 -ncmoe 48 -n 128 -r 3
   ```

   Lower the `-ncmoe` value to keep more expert layers on the GPU and compare tok/s.
2. **Sweep threads (`-Threads`).** MoE expert compute is bandwidth-bound, so more
   threads isn't always faster — past RAM-bandwidth saturation extra threads just
   contend with sampling. Benchmark 8 / 12 / 16 / 20; the peak is often lower than expected.
3. **RAM bandwidth is the hardware ceiling.** Enable XMP/EXPO in BIOS and populate
   both channels — this moves tok/s more than any flag when experts live in RAM.
4. **`-Batch`/`-UBatch` speed up *prefill*, not generation.** They're already raised
   to 4096 for MoE, which helps long-prompt TTFT but not steady-state tok/s.
5. **`-Thinking:$false`** *feels* faster (fewer tokens generated), but raw tok/s is unchanged.
6. **Speculative decoding isn't worth it here.** Only ~3B params are active per token
   in this 35B-A3B MoE, so draft-model overhead rarely pays off.

### Prompt caching for coding agents (OpenCode, Cursor, etc.)

Agents resend the system prompt **and** the whole conversation every turn. That's
fine — `llama-server` caches a stable leading prefix by default (`cache_prompt: true`),
so an unchanged system prompt is **not** re-prefilled each turn. Two things break
that cache and cause the slow "reprocessing from the system prompt" pause:

1. **Dropped reasoning blocks.** With thinking on, the model emits `<think>` blocks,
   but many agents strip `reasoning_content` from history when they replay the
   conversation. The KV cache then diverges right after the first assistant turn and
   everything after it is reprocessed every turn. We mitigate this server-side with
   `--reasoning-preserve` (always set in `docker-compose.yml`) — the standard
   llama.cpp flag that keeps reasoning in the full history for templates that
   advertise `supports_preserve_reasoning` (Qwen3.6 does). **Also make sure the
   client sends `reasoning_content` back** — e.g. in OpenCode don't strip thinking
   from history — otherwise the server can't rebuild it. If your agent can't preserve
   thinking, running that agent with `-Thinking:$false` sidesteps the issue entirely
   (no `<think>` block to drop, so the prefix cache just works).
2. **Dynamic content at the top of the prompt** (timestamps, changing tool order).
   Keep the prefix byte-identical across turns; move any volatile text to the end of
   the user message. This is the case where `--cache-reuse` (see above) can help.

## Requirements

| Component | Minimum |
|-----------|---------|
| GPU | NVIDIA RTX 3060 12 GB (RTX 4080 16 GB recommended) |
| RAM | 32 GB (96 GB recommended for MoE offload) |
| OS | Windows 10/11 |
| Docker | Desktop with WSL2 backend + **WSL Integration enabled** (Settings > Resources > WSL Integration) |
| Python | 3.x + [uv](https://docs.astral.sh/uv/getting-started/installation/) (`irm https://astral.sh/uv/install.ps1 \| iex`) |
| Git | Any recent version |
| Hugging Face CLI | `hf` installed automatically by `setup.ps1` via `uv tool install --force hf` |

All prerequisites are verified by `setup.ps1` step 0. If anything is missing,
the script prints the exact install command and exits.

> **GPU in Docker:** After installing Docker Desktop, enable WSL Integration
> (`Settings > Resources > WSL Integration`) and add your WSL distro. Without
> this, `docker run --gpus all` fails with a segmentation fault.

> **Symlinks:** Model files are symlinked from the Hugging Face cache into
> `.\models\` to avoid duplicating multi-GB files. This requires either
> **Developer Mode** enabled or running as Administrator. Without either,
> files are copied instead (same result, just uses more disk).

## License

Scripts: public domain. Models: see their respective Hugging Face model cards.

## Support

If this saved you a weekend of fighting CUDA errors, guessing at `--n-cpu-moe`
values, or explaining to your wallet why the cloud inference bill looked like that,
consider [buying me a coffee](https://www.buymeacoffee.com/kibotu).
