# LLM Server

[![Medium](https://img.shields.io/badge/Medium-@kibotu-000000?style=flat-square&logo=medium&logoColor=white)](https://medium.com/@kibotu/two-paths-to-local-llm-servers-windows-nvidia-vs-mac-apple-silicon-1e28d606f600?sk=a5d9989d124d7f9b844927f0f545ed09)

Turn an idle Windows + NVIDIA machine into a private, OpenAI-compatible LLM server.
Two scripts, one Docker command, sensible defaults for **Qwen3.6-35B-A3B** with vision.

## Quick start

```powershell
.\setup.ps1     # install Docker + hf CLI, generate API key, pull image, download model
.\run.ps1       # start the server (stays in the foreground, streams logs)
```

Before the first run, copy `.env.example` to `.env` and add your Hugging Face token.
`setup.ps1` then generates a random `LLAMA_API_KEY` into `.env`, and `run.ps1` prints
both the endpoint and the key on startup.

That's it — the server is now serving an OpenAI-compatible API at `http://localhost:8899/v1`.

## Connect a client

- **Base URL:** `http://<host-ip>:8899/v1`
- **API key:** the `LLAMA_API_KEY` from `.env`, sent as `Authorization: Bearer <key>`

Every request is validated against `LLAMA_API_KEY` by the usage-tracker proxy; a
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

3. Start OpenCode — it defaults to `llama-at-home/qwen36-35b`. Switch models with the
   picker or the `"model"` field.

The shipped config also sets sensible context limits, auto-compaction, and tool
permissions; trim the `permission` / `mcp` blocks to taste — they're just a demo.

## Models

| Alias | Model | Size | Vision | Notes |
|-------|-------|------|--------|-------|
| `qwen36` | Qwen3.6-35B-A3B IQ4_XS | ~17 GB | Yes | **Default.** MoE, experts offloaded to RAM. |
| `qwen35-9b` | Qwen3.5-9B Q4_K_M | ~5 GB | Yes | Lighter, dense, faster. |

Both download on demand into `.\models\` (gitignored). Switch with `-Model`:

```powershell
.\run.ps1 -Model qwen35-9b
```

## The two scripts

The whole project is two PowerShell scripts plus the Compose stack — nothing else to learn.

### `run.ps1` — start, reconcile, stop

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

Re-running is safe: Docker Compose recreates the container only when the config
actually changes. Ctrl+C stops log streaming; the server keeps running.

### `setup.ps1` — setup + update in one

Installs Docker Desktop, verifies GPU access, installs the latest Hugging Face CLI,
pulls the latest llama.cpp image, rebuilds the usage-tracker proxy, downloads the
model (via the `hf` CLI reading `HF_TOKEN` from `.env`), opens the firewall, and
prunes old Docker layers. Idempotent — re-run it to update.

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

## How it works

```
client ──▶ usage-tracker (:8899) ──▶ llama.cpp server (:8888, GPU)
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
| Docker | Desktop with WSL2 backend |
| Python | 3.x (for the Hugging Face CLI) |

## License

Scripts: public domain. Models: see their respective Hugging Face model cards.

## Support

If this saved you a weekend of fighting CUDA errors, guessing at `--n-cpu-moe`
values, or explaining to your wallet why the cloud inference bill looked like that,
consider [buying me a coffee](https://www.buymeacoffee.com/kibotu).
