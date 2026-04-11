# LLM Server with Benchmarking

LLM server running in Docker with usage tracking and high-load benchmarking tools.

## Quick Start

### 1. Start Server (32k context)
```bash
docker-compose up -d
```

### 2. Start Server (128k context)
```bash
cp .env.128k .env
docker-compose restart llm
```

### 3. Run Benchmark
```bash
# Install dependencies
pip install -r requirements-benchmark.txt

# Run benchmark
python benchmark.py --test standard

# Or use helper script (Windows)
.\run-benchmark.ps1 standard

# Or use helper script (Linux/Mac)
./run-benchmark.sh standard
```

## Benchmark Test Suites

- `quick` - Quick test (~30s)
- `standard` - Recommended (~5-10 min)
- `stress` - High load (~10-15 min)
- `context-scaling` - Test 1k to 128k contexts (~15-20 min)
- `all` - Complete suite (~30-45 min)

## Analyze Results

```bash
# Summary
python analyze-benchmark.py benchmark_results.json

# Detailed with recommendations
python analyze-benchmark.py benchmark_results.json --all
```

## Expected Performance (RTX 4080, 16GB VRAM)

| Context | RPS | Latency (P50) | VRAM |
|---------|-----|---------------|------|
| 1k      | 5-10 | 200-500ms | ~8 GB |
| 10k     | 2-5 | 500-2000ms | ~9 GB |
| 50k     | 0.5-1.5 | 2-5s | ~12 GB |
| 100k    | 0.2-0.5 | 5-15s | ~15 GB |
| 128k    | 0.1-0.3 | 10-30s | ~16 GB |

**Max context before VRAM spillover: ~138k tokens**

## Monitor GPU

```bash
nvidia-smi -l 1
```

## Configuration

- `docker-compose.yml` - Server configuration
- `.env` - Environment variables (CONTEXT_SIZE, MODEL_FILE)
- `.env.128k` - Pre-configured for 128k context
- `benchmark.py` - Benchmark script
- `analyze-benchmark.py` - Results analysis
- `run-benchmark.ps1` / `run-benchmark.sh` - Helper scripts
