# LLM Server

Private OpenAI-compatible inference on your NVIDIA GPU. Zero per-token cost, no rate limits, code stays on your LAN.

## Quick Start

```powershell
.\setup.ps1                    # pulls image, downloads 9B model, configures firewall
.\run.ps1                      # starts server on port 8899
.\test.ps1                     # verify it works
```

API endpoint: `http://localhost:8899/v1`

---

## Models

| Alias | Model | Size | VRAM (MoE offload) | Notes |
|-------|-------|------|-------------------|-------|
| `9b` | Qwen3.5-9B Q4_K_M | ~5 GB | ~8 GB | Default. Fast, good for agentic loops. |
| `35b` | Qwen3.6-35B-A3B Q4_K_S | ~21 GB | ~6-8 GB | Auto-picks Qwen3.6 if present. |
| `qwen3635ba3b` | Qwen3.6-35B-A3B Q4_K_S | ~21 GB | ~6-8 GB | Explicit Qwen3.6 selection. |
| `qwen3635ba3b2bit` | Qwen3.6-35B-A3B Q2_K_XL | ~13 GB | ~4-5 GB | Ultra-low VRAM. Setup: `-IncludeQwen36Q2` |
| `qwen3635ba3b4bit` | Qwen3.6-35B-A3B IQ4_XS | ~14 GB | ~5-6 GB | imatrix quant. Setup: `-IncludeQwen36IQ4` |
| `qwen36heretic` | Qwen3.6-35B-A3B Uncensored Heretic MTP | ~22 GB | ~6-8 GB | Uncensored + MTP. Setup: `-IncludeQwen36Heretic` |
| `qwen36opus47` | Qwen3.6-35B-A3B Claude Opus Distill MTP | ~20 GB | ~6-8 GB | Claude 4.7 Opus reasoning distill + MTP. Best for code. Setup: `-IncludeQwen36Opus47` |
| `qwen3uncensored8b` | Qwen3-8B-Uncensor-v2 Q4_K_M | ~5 GB | ~8 GB | Uncensored 8B variant. |
| `gemma312` | Gemma 3 12B IT Q4_K_M | ~7 GB | ~9 GB | Setup: `-IncludeGemma312` |
| `gemma426ba4b` | Gemma 4 26B-A4B IT Q4_K_M | ~16 GB | ~8-10 GB | MoE. Setup: `-IncludeGemma426BA4B` |

Switch models: `.\run.ps1 -Model <alias> -Restart`

Models are downloaded to the HuggingFace cache (`HF_HOME` env var, or `~/.cache/huggingface/`) and linked to `models/` for Docker.

---

## run.ps1

```powershell
.\run.ps1 [options]
```

### Model & Server

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Model` | `9b` | Model alias (see table above) |
| `-Restart` | - | Force restart container |
| `-Stop` | - | Stop server |
| `-Context` | `262144` | Context window (tokens) |

### Inference Features

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Thinking` | off | Extended reasoning mode |
| `-Mtp` | off | Multi-Token Prediction (requires MTP model like `qwen36opus47`) |
| `-MtpTokens` | `4` | Extra tokens to predict with MTP (1-16) |

### MoE Offloading

For MoE models (`35b`, `qwen3635ba3b*`, `qwen36opus47`, `gemma426ba4b`):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-MoeOffload` | `auto` | `auto`/`all` = experts to CPU, `off` = full GPU, `N` = first N layers |

### Performance Tuning

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Threads` | `0` (auto) | CPU threads. Auto: 20 on 32-core, 12 on 16-core. |
| `-Batch` | `2048` | Physical batch size. Auto-bumped to 4096 for MoE. |
| `-UBatch` | `1024` | Micro-batch size (≤ Batch). Auto-bumped to 4096 for MoE. |
| `-KvCache` | `q8_0` | KV cache type: `q4_0` (smallest), `q8_0` (balanced), `f16` (best) |

### Speculative Decoding

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-DraftModelFile` | - | Draft GGUF filename in `models/` |
| `-DraftMin` | `5` | Min draft tokens before verification |
| `-DraftMax` | `16` | Max draft tokens per step |
| `-DraftGpuLayers` | `99` | GPU layers for draft model |

### Advanced

| Parameter | Description |
|-----------|-------------|
| `-ExtraFlags` | Pass-through to `llama-server` |

### Examples

```powershell
.\run.ps1 -Model qwen36heretic -MoeOffload auto -Thinking -Mtp  # uncensored + MTP
.\run.ps1 -Model qwen36opus47 -MoeOffload auto -Thinking -Mtp   # Opus distill + MTP (best for code)
.\run.ps1 -Model qwen3635ba3b2bit -MoeOffload auto              # 2-bit, minimal VRAM
.\run.ps1 -Model gemma426ba4b -Thinking                         # Gemma 4 MoE
.\run.ps1 -Batch 4096 -UBatch 4096 -Threads 24                  # perf tuning
```

---

## setup.ps1

```powershell
.\setup.ps1 [options]
```

Downloads Qwen3.5-9B by default. All other models require explicit flags.

### Additional Models

| Parameter | Model | Size |
|-----------|-------|------|
| `-IncludeQwen3635ba3b` | Qwen3.6-35B-A3B Q4_K_S | ~21 GB |
| `-IncludeQwen3Uncensored8b` | Qwen3-8B-Uncensor-v2 Q4_K_M | ~5 GB |
| `-IncludeQwen36Q2` | Qwen3.6-35B-A3B Q2_K_XL (2-bit) | ~13 GB |
| `-IncludeQwen36IQ4` | Qwen3.6-35B-A3B IQ4_XS | ~14 GB |
| `-IncludeQwen36Heretic` | Qwen3.6-35B-A3B Uncensored Heretic MTP | ~22 GB |
| `-IncludeQwen36Opus47` | Qwen3.6-35B-A3B Claude Opus Distill MTP Q4_K_M | ~20 GB |
| `-IncludeGemma312` | Gemma 3 12B IT Q4_K_M | ~7 GB |
| `-IncludeGemma426BA4B` | Gemma 4 26B-A4B IT Q4_K_M | ~16 GB |

```powershell
.\setup.ps1 -IncludeQwen36Opus47 -IncludeQwen36Heretic  # download both MTP models
.\setup.ps1 -Model 35b                                  # shorthand for -IncludeQwen3635ba3b
```

---

## Client Configuration

Base URL: `http://<host-ip>:8899/v1`  
API Key: any string (not validated)

**Cursor / Continue / OpenAI SDK**: Set base URL, any API key.

**OpenCode** (`~/.config/opencode/opencode.json`):

```json
{
  "provider": {
    "llama-at-home": {
      "name": "Local LLM",
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://<host-ip>:8899/v1" },
      "models": {
        "Qwen3.5-9B": { "name": "Qwen3.5-9B" },
        "Qwen3.6-35B-A3B": { "name": "Qwen3.6-35B-A3B" }
      }
    }
  }
}
```

---

## MoE Expert Offloading

MoE models (Qwen 35B, Gemma 4 26B-A4B) have many "expert" sub-networks but only activate a few per token. CPU expert offloading keeps attention on GPU while experts run on CPU/RAM.

**Result**: Run 35B models on 8-12 GB VRAM instead of 20+ GB.

```powershell
.\run.ps1 -Model qwen3635ba3b -MoeOffload auto   # default: experts to CPU
.\run.ps1 -Model qwen3635ba3b -MoeOffload off    # full GPU (needs 20+ GB)
.\run.ps1 -Model qwen3635ba3b -MoeOffload 30     # first 30 layers' experts to CPU
```

---

## Multi-Token Prediction (MTP)

MTP predicts multiple tokens in parallel for ~25% speedup on code workloads. Requires a model with native MTP support.

**Note:** MTP models require a custom llama.cpp build. The first run with `-Mtp` will build the image (10-20 minutes). Subsequent runs use the cached image.

| Model | Best `-MtpTokens` | Notes |
|-------|-------------------|-------|
| `qwen36heretic` | 4 (default) | Uncensored, good general MTP |
| `qwen36opus47` | 2 (auto-set) | Claude Opus distill. Best for code. |

```powershell
.\run.ps1 -Model qwen36heretic -Mtp                 # uncensored + MTP
.\run.ps1 -Model qwen36opus47 -Mtp                  # Opus distill + MTP (auto n=2)
.\run.ps1 -Model qwen36opus47 -Mtp -MtpTokens 1     # Opus distill, better for prose
```

### Standalone MTP Runner

For direct control over MTP settings, use `run-mtp.ps1`:

```powershell
.\run-mtp.ps1                                        # Code-optimized defaults (n=2)
.\run-mtp.ps1 -MtpTokens 1                           # Prose/creative mode
.\run-mtp.ps1 -Context 65536 -KvCache q4_0           # Longer context
.\run-mtp.ps1 -ReasoningBudget 16384                 # Hard math/logic problems
```

### Model Card Recommendations

Based on [Dyluhn/lordx64-Qwen3.6-35B-A3B-Claude-4.7-Opus-Reasoning-Distilled-MTP-GGUF](https://huggingface.co/Dyluhn/lordx64-Qwen3.6-35B-A3B-Claude-4.7-Opus-Reasoning-Distilled-MTP-GGUF):

| Setting | Code Workloads | Prose/Creative |
|---------|---------------|----------------|
| `--spec-draft-n-max` | **2** (89-91% accept, ~25% speedup) | **1** (more reliable) |
| `--cache-type-k/v` | `q8_0` (quality) or `q4_0` (longer ctx) | `q8_0` |
| `--parallel` | **1** (required for MTP) | **1** |
| `--reasoning-budget` | 4096 (default) | 16384 (hard problems) |

**Architecture:** `qwen35moe_mtp` — this is MoE + MTP working together.

### MTP + TBQ4 (Optional, Experimental)

The [Indra's Mirror fork](https://indrasmirror.au/blog-mtp-shared-tensors-200k) adds TBQ4 fused flash attention for massive context on 27B dense models (80-87 tok/s at 262K).

**TBQ4 is separate from MTP** — you don't need it to use MTP. The lordx64 model card recommends standard `q8_0` or `q4_0` KV cache.

| KV Cache | Use Case | Notes |
|----------|----------|-------|
| `q8_0` | Default, quality | Model card recommendation |
| `q4_0` | Longer context (65k+) | Good for 16GB VRAM |
| `tbq4_0` | Experimental on MoE | May have alignment issues |

**Recommended Settings for RTX 4080 + 35B MoE:**

```powershell
# Code-optimized (model card defaults)
.\run-mtp.ps1 -Model "lordx64-distill-MTP-Q4_K_M.gguf" `
              -Context 32768 `
              -KvCache q8_0 `
              -MtpTokens 2

# Prose/creative
.\run-mtp.ps1 -MtpTokens 1 -ReasoningBudget 8192
```

---

## Benchmarking

```powershell
.\benchmark.ps1                  # quick tok/s check
.\benchmark.ps1 -Runs 5          # stable average

# Python suite
pip install -r requirements-benchmark.txt
python benchmark.py --test standard
python analyze-benchmark.py benchmark_results.json
```

### A/B Testing

```powershell
.\run.ps1 -Model 9b -Batch 2048 -UBatch 512 -Restart && .\benchmark.ps1 -Runs 5
.\run.ps1 -Model 9b -Batch 4096 -UBatch 1024 -Restart && .\benchmark.ps1 -Runs 5
```

---

## Host Control API

Remote model switching via HTTP.

```powershell
.\start-control.ps1   # starts on port 8898
```

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/models` | GET | Available models + last switch state |
| `/status` | GET | Current status + health |
| `/switch` | POST | Switch model, streams SSE progress |

```powershell
Invoke-WebRequest -Uri "http://localhost:8898/switch" -Method POST `
  -ContentType "application/json" -Body '{"model":"35b","thinking":true,"restart":true}'
```

---

## Tailscale

For secure remote access without port forwarding:

1. Install [Tailscale](https://tailscale.com) on host + clients
2. Use Tailscale IP: `tailscale ip -4`

---

## Requirements

| Component | Minimum |
|-----------|---------|
| GPU | NVIDIA RTX 3060 12 GB |
| RAM | 32 GB |
| OS | Windows 10/11 |
| Docker | Desktop with WSL2 backend |

---

## Docker Commands

```powershell
docker compose logs -f    # stream logs
docker compose down       # stop everything
docker ps                 # running containers
```

---

## Files

```
setup.ps1             Setup (Docker, models, firewall)
run.ps1               Start/stop/configure server
start-control.ps1     Host control API (port 8898)
test.ps1              Connectivity test
benchmark.ps1         Quick benchmark
benchmark.py          Python benchmark suite
analyze-benchmark.py  Analyze results
docker-compose.yml    Service definitions
models/               Downloaded GGUFs (gitignored)
```

---

## License

Scripts: public domain. Models: see respective Hugging Face model cards.
