<#
.SYNOPSIS
    Start or restart the LLM server via Docker.

.PARAMETER Model
    Which model to load: "9b" (default), "35b", "qwen3635ba3b", "qwen36heretic" (uncensored MTP), "qwen36opus47" (Claude 4.7 Opus distill MTP), "gemma312", or "gemma426ba4b"

.PARAMETER Restart
    Force restart the container

.PARAMETER Context
    Context window size (default: 32768)

.PARAMETER Thinking
    Enable thinking/reasoning mode (default: false)

.PARAMETER Mtp
    Enable Multi-Token Prediction (requires MTP-enabled model like qwen36opus47). Predicts multiple tokens in parallel for faster generation.

.PARAMETER MtpTokens
    Number of extra tokens to predict with MTP (default: 4). Only used when -Mtp is enabled.

.PARAMETER Threads
    CPU thread count for llama.cpp (-t). Use 0 for auto (recommended): scales with logical CPU count
    (e.g. 32 logical -> 20 threads on a high-end desktop). After benchmarking, try 16-24 on Core i9-class CPUs; see README.

.PARAMETER Batch
    Physical batch size -b (tokens batched for matmuls). Higher can improve throughput at the cost of VRAM.

.PARAMETER UBatch
    Micro-batch size -ub (chunk size within -b). Must be <= -b; often set to roughly half of -b for tuning.

.PARAMETER DraftModelFile
    Optional draft GGUF filename under models/; enables speculative decoding (-md) when set.

.PARAMETER DraftMin
    --draft-min: minimum draft tokens before target verification (typical range 2-8).

.PARAMETER DraftMax
    --draft-max: maximum draft tokens per speculative step (typical range 8-32; lower if VRAM or acceptance is poor).

.PARAMETER DraftGpuLayers
    -ngld: GPU layers for the draft model (0 = CPU draft, 99 = all on GPU when supported).

.PARAMETER MoeOffload
    MoE expert offloading strategy for large MoE models (Qwen 35B, Gemma 4 26B-A4B, etc.):
    - "auto" (default): Enable expert offloading for MoE models, disable for dense models
    - "off": Disable offloading (requires full VRAM for model)
    - "all": Offload ALL experts to CPU (minimal VRAM usage, slower token gen)
    - N (number): Offload experts from first N layers to CPU (fine-tuning)
    
    This keeps attention layers on GPU for speed while offloading routed expert FFN to CPU.
    Dramatically reduces VRAM requirements for MoE models with modest performance impact.

.PARAMETER KvCache
    KV cache quantization type (default: q8_0):
    - "q4_0": Smallest, fastest, slight quality loss
    - "q8_0": Good balance of quality and size (recommended for MoE)
    - "f16": Best quality, uses more VRAM

.PARAMETER ExtraFlags
    Appended verbatim to the llama-server command (advanced; see llama.cpp server --help).

.PARAMETER Stop
    Stop the server

.EXAMPLE
    .\run.ps1                  # Start with 9B model
    .\run.ps1 -Model 35b       # Start with 35B MoE model (prefers Qwen3.6 if present)
    .\run.ps1 -Model qwen3635ba3b # Start with Qwen3.6-35B-A3B
    .\run.ps1 -Model qwen3635ba3b2bit # Start with Qwen3.6-35B-A3B-UD-Q2_K_XL (2-bit, CPU experts)
    .\run.ps1 -Model qwen3635ba3b4bit # Start with Qwen3.6-35B-A3B IQ4_XS (4-bit)
    .\run.ps1 -Model qwen36heretic -MoeOffload auto -Thinking -Mtp # Uncensored + MTP
    .\run.ps1 -Model qwen36opus47 -MoeOffload auto -Thinking -Mtp # Claude Opus distill + MTP
    .\run.ps1 -Model gemma312  # Gemma 3 12B IT (.\setup.ps1 -IncludeGemma312)
    .\run.ps1 -Model gemma426ba4b # Gemma 4 26B-A4B IT (.\setup.ps1 -IncludeGemma426BA4B)
    
    # MoE Expert Offloading (for 35B and larger MoE models with limited VRAM):
    .\run.ps1 -Model qwen3635ba3b2bit -MoeOffload auto  # Auto-detect: offload experts to CPU
    .\run.ps1 -Model qwen3635ba3b -MoeOffload all       # Offload ALL experts to CPU (lowest VRAM)
    .\run.ps1 -Model qwen3635ba3b -MoeOffload 30        # Offload first 30 layers' experts to CPU
    .\run.ps1 -Model qwen3635ba3b -MoeOffload off       # No offloading (needs ~20GB+ VRAM)
    
    # Multi-Token Prediction (MTP) - requires MTP-enabled model:
    .\run.ps1 -Model qwen36heretic -Mtp                 # Uncensored with MTP
    .\run.ps1 -Model qwen36opus47 -Mtp -MtpTokens 2     # Opus distill (n=2 optimal for code)
    
    # Performance tuning:
    .\run.ps1 -Batch 4096 -UBatch 4096              # Higher batch for MoE (better PP speed)
    .\run.ps1 -Threads 24 -Batch 4096 -UBatch 2048  # Many-core CPU (benchmark vs auto)
    .\run.ps1 -KvCache q8_0                         # Better quality KV cache (default)
    .\run.ps1 -KvCache q4_0                         # Smaller KV cache (save VRAM)
    .\run.ps1 -DraftModelFile Qwen3-1.7B-Q4_K_M.gguf -DraftMax 12 -DraftMin 4
    .\run.ps1 -Restart         # Restart server
    .\run.ps1 -Stop            # Stop server
#>

param(
    [ValidateSet("9b", "35b", "qwen3635ba3b", "gemma312", "gemma426ba4b", "qwen3635ba3b2bit", "qwen3635ba3b4bit", "qwen36heretic", "qwen36opus47", "qwen3uncensored8b")]
    [string]$Model = "9b",

    [switch]$Restart,

    [int]$Context = 262144, # 131072, # 32768

    [switch]$Thinking,

    [switch]$Mtp,

    [ValidateRange(1, 16)]
    [int]$MtpTokens = 4,

    [ValidateRange(0, 256)]
    [int]$Threads = 0,

    [int]$Batch = 2048,

    [int]$UBatch = 1024,

    [string]$DraftModelFile = "",

    [int]$DraftMin = 5,

    [int]$DraftMax = 16,

    [int]$DraftGpuLayers = 99,

    # MoE Expert Offloading: offload routed experts to CPU for large MoE models
    # "auto" = enable for MoE models (35b, qwen3635ba3b, qwen3635ba3b2bit, qwen3635ba3b4bit, gemma426ba4b)
    # "off"  = disable (full GPU, needs enough VRAM)
    # "all"  = offload ALL experts to CPU (minimal VRAM, slower)
    # N      = offload experts from first N layers to CPU (fine-tuning)
    [ValidatePattern("^(auto|off|all|\d+)$")]
    [string]$MoeOffload = "auto",

    # KV cache quantization: q4_0 (smaller), q8_0 (balanced), f16 (best), tbq4_0 (MTP+TBQ4 mode)
    [ValidateSet("q4_0", "q8_0", "f16", "tbq4_0")]
    [string]$KvCache = "q8_0",

    [string]$ExtraFlags = "",

    [switch]$Stop
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Ensure Docker is in PATH (for D: drive installation)
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = @(
        "D:\Docker\resources\bin",
        "C:\Program Files\Docker\Docker\resources\bin"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($dockerBin) {
        $env:PATH = "$dockerBin;$env:PATH"
    }
}

# --- llama.cpp -t (CPU threads) -------------------------------------------------
# With -ngl 99 the GPU runs the transformer; the CPU still does tokenization, sampling, and
# bookkeeping. Too few threads underuses a fast CPU; too many can add overhead.
# Auto picks a sensible default from logical CPU count (Environment.ProcessorCount on Windows).
$LogicalCpus = [Environment]::ProcessorCount
$ThreadsFromAuto = $false
if ($Threads -le 0) {
    $ThreadsFromAuto = $true
    if ($LogicalCpus -ge 32) {
        # e.g. Core i9-13900K (32 logical):20 is a strong default; try 16-24 in benchmarks.
        $Threads = 20
    } elseif ($LogicalCpus -ge 16) {
        $Threads = 12
    } else {
        $Threads = [math]::Max(4, [int][math]::Ceiling($LogicalCpus / 2.0))
    }
}

function Write-Step([string]$Msg) { Write-Host "`n=== $Msg" -ForegroundColor Cyan }
function Write-Ok([string]$Msg) { Write-Host "  OK $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host "  -- $Msg" -ForegroundColor Yellow }
function Write-Err([string]$Msg) { Write-Host "  !! $Msg" -ForegroundColor Red }
function Write-Info([string]$Msg) { Write-Host "  -> $Msg" -ForegroundColor White }

# Ensure Docker Desktop is running
function Start-DockerDesktop {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        Write-Err "Docker not found. Run .\setup.ps1 first."
        exit 1
    }

    $dockerInfo = docker info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Docker Desktop not running, starting..."
        
        # Find Docker Desktop executable
        $dockerExe = @(
            "D:\Docker\Docker Desktop.exe",
            "C:\Program Files\Docker\Docker\Docker Desktop.exe",
            "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        
        if (-not $dockerExe) {
            Write-Err "Docker Desktop executable not found"
            exit 1
        }
        
        Start-Process $dockerExe -WindowStyle Hidden
        
        $timeout = 120
        $start = Get-Date
        while ($true) {
            Start-Sleep -Seconds 3
            $dockerInfo = docker info 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Docker Desktop started"
                return
            }
            if (((Get-Date) - $start).TotalSeconds -gt $timeout) {
                Write-Err "Docker Desktop failed to start within ${timeout}s"
                exit 1
            }
            Write-Host "." -NoNewline -ForegroundColor Gray
        }
    }
}

# Get local IP for connection info
function Get-LocalIp {
    $adapters = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
        Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" })
    
    if ($adapters.Count -eq 0) { return "127.0.0.1" }
    
    $ethernet = @($adapters | Where-Object { $_.InterfaceAlias -like "Ethernet*" })
    if ($ethernet.Count -gt 0) { return $ethernet[0].IPAddress }
    
    $wifi = @($adapters | Where-Object { $_.InterfaceAlias -like "Wi-Fi*" })
    if ($wifi.Count -gt 0) { return $wifi[0].IPAddress }
    
    return $adapters[0].IPAddress
}

# Main
Write-Step "LLM Server (Docker)"

Start-DockerDesktop

# Handle stop (stop both standard and MTP containers)
if ($Stop) {
    Write-Step "Stopping server"
    docker compose -f "$ScriptDir\docker-compose.yml" down 2>&1 | Out-Null
    if (Test-Path "$ScriptDir\docker-compose.mtp.yml") {
        docker compose -f "$ScriptDir\docker-compose.yml" -f "$ScriptDir\docker-compose.mtp.yml" down 2>&1 | Out-Null
    }
    Write-Ok "Server stopped"
    exit 0
}

# Select model file (paths under models/ use forward slashes for the Linux container)
$modelsDir = Join-Path $ScriptDir "models"
if (-not (Test-Path $modelsDir)) {
    Write-Err "Models directory not found: $modelsDir"
    Write-Info "Run .\setup.ps1 first"
    exit 1
}
$modelsRoot = (Resolve-Path $modelsDir).Path.TrimEnd('\')
$ModelFile = if ($Model -eq "35b") {
    $f36 = Get-ChildItem "$ScriptDir\models" -Filter "*Qwen3.6-35B-A3B*Q4_K_S*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f36) {
        $f36.Name
    } else {
        $f35 = Get-ChildItem "$ScriptDir\models" -Filter "*Qwen3.5-35B-A3B*Q4_K_XL*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f35) { $f35.Name } else { "Qwen3.6-35B-A3B-UD-Q4_K_S.gguf" }
    }
} elseif ($Model -eq "qwen3635ba3b") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "*Qwen3.6-35B-A3B*Q4_K_S*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "Qwen3.6-35B-A3B-UD-Q4_K_S.gguf" }
} elseif ($Model -eq "qwen3635ba3b2bit") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "*Qwen3.6-35B-A3B-UD-Q2_K_XL*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf" }
} elseif ($Model -eq "qwen3635ba3b4bit") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "*Qwen3.6-35B-A3B*IQ4_XS*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf" }
} elseif ($Model -eq "gemma312") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "gemma-3-12b-it-Q4_K_M.gguf" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "gemma-3-12b-it-Q4_K_M.gguf" }
} elseif ($Model -eq "gemma426ba4b") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" }
} elseif ($Model -eq "qwen36heretic") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "*Qwen3.6-35B-A3B-uncensored-heretic*Q4_K_M*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-Q4_K_M.gguf" }
} elseif ($Model -eq "qwen36opus47") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "*lordx64-distill-MTP*Q4_K_M*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "lordx64-distill-MTP-Q4_K_M.gguf" }
} elseif ($Model -eq "qwen3uncensored8b") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "*Qwen3-8B-Uncensor*Q4_K_M*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "Qwen3-8B-Uncensor-v2.Q4_K_M.gguf" }
} else {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "*9B*Q4_K_M*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "Qwen3.5-9B-Q4_K_M.gguf" }
}

$ModelPath = [System.IO.Path]::GetFullPath(
    (Join-Path $modelsRoot ($ModelFile -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
if (-not (Test-Path $ModelPath)) {
    Write-Err "Model not found: $ModelPath"
    Write-Info "Run .\setup.ps1 to download models"
    exit 1
}

$ModelSize = [math]::Round((Get-Item $ModelPath).Length / 1GB, 2)

# Determine if this is an MoE model that benefits from expert offloading
$IsMoeModel = $Model -in @("35b", "qwen3635ba3b", "qwen3635ba3b2bit", "qwen3635ba3b4bit", "gemma426ba4b", "qwen36heretic", "qwen36opus47")
$MoeFlags = ""

if ($IsMoeModel) {
    # For MoE models, use higher batch sizes by default for better prompt processing
    # (GPU offload prompt processing threshold is 32 tokens minimum)
    if ($Batch -lt 4096 -and $MoeOffload -ne "off") {
        $Batch = 4096
        $UBatch = 4096
    }
    
    switch ($MoeOffload) {
        "auto" {
            # Auto mode: offload all experts to CPU, keep attention on GPU
            # This is the best balance for single-GPU setups with limited VRAM
            $MoeFlags = "--cpu-moe"
        }
        "all" {
            # Explicit all: same as auto, offload ALL experts to CPU
            $MoeFlags = "--cpu-moe"
        }
        "off" {
            # No offloading - requires enough VRAM for full model + KV cache
            $MoeFlags = ""
        }
        default {
            # Numeric value: offload first N layers' experts to CPU
            if ($MoeOffload -match '^\d+$') {
                $MoeFlags = "--n-cpu-moe $MoeOffload"
            }
        }
    }
}

Write-Info "Model: $ModelFile ($ModelSize GB)"
Write-Info "Context: $Context tokens"
Write-Info "Reasoning: $(if ($Thinking) { 'on' } else { 'off' })"
if ($ThreadsFromAuto) {
    Write-Info "Threads: $Threads (auto from $LogicalCpus logical CPUs)"
} else {
    Write-Info "Threads: $Threads (manual)"
}
Write-Info "Batch/UBatch: $Batch/$UBatch"
Write-Info "KV Cache: $KvCache"

if ($IsMoeModel) {
    if ($MoeFlags -ne "") {
        Write-Info "MoE Offload: $MoeOffload (experts -> CPU, attention -> GPU)"
    } else {
        Write-Info "MoE Offload: off (full GPU)"
    }
} else {
    Write-Info "MoE Offload: N/A (dense model)"
}

if ($Batch -lt $UBatch) {
    Write-Warn "Batch ($Batch) is smaller than UBatch ($UBatch). This usually hurts throughput."
}

$SpeculativeFlags = ""
if (-not [string]::IsNullOrWhiteSpace($DraftModelFile)) {
    $draftPath = [System.IO.Path]::GetFullPath(
        (Join-Path $modelsRoot ($DraftModelFile -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    if (-not (Test-Path $draftPath)) {
        Write-Err "Draft model not found: $draftPath"
        Write-Info "Place the draft model in .\models and pass the filename via -DraftModelFile"
        exit 1
    }
    $SpeculativeFlags = "-md /models/$DraftModelFile -ngld $DraftGpuLayers --draft-max $DraftMax --draft-min $DraftMin"
    Write-Info "Speculative: on (draft=$DraftModelFile, min=$DraftMin, max=$DraftMax, ngld=$DraftGpuLayers)"
} else {
    Write-Info "Speculative: off"
}

# MTP (Multi-Token Prediction) - requires a model with native MTP support
# Uses am17an's branch flags: --spec-type mtp --spec-draft-n-max N
# MTP models require custom llama.cpp build (docker-compose.mtp.yml)
$IsMtpModel = $Model -in @("qwen36heretic", "qwen36opus47")
$MtpFlags = ""
$UseMtpBuild = $false

if ($IsMtpModel -and $Mtp) {
    # MTP model with -Mtp flag: enable MTP speculative decoding
    $UseMtpBuild = $true
    # Optimal MtpTokens for qwen36opus47 is 2 (per HF model card), 3 for others
    if ($Model -eq "qwen36opus47" -and $MtpTokens -eq 4) {
        $MtpTokens = 2
    } elseif ($MtpTokens -eq 4) {
        $MtpTokens = 3  # Default for MTP per blog post
    }
    $MtpFlags = "--spec-type mtp --spec-draft-n-max $MtpTokens"
    
    # For MTP mode, use q4_0 KV cache by default (faster, good quality)
    # User can override with -KvCache tbq4_0 for TBQ4 fused flash attention
    if ($KvCache -eq "q8_0") {
        $KvCache = "q4_0"
        Write-Info "KV Cache: q4_0 (auto for MTP, use -KvCache tbq4_0 for TBQ4 mode)"
    } elseif ($KvCache -eq "tbq4_0") {
        Write-Info "KV Cache: tbq4_0 (TBQ4 fused flash attention)"
    }
    Write-Info "MTP: on (spec-draft-n-max=$MtpTokens)"
} elseif ($IsMtpModel) {
    # MTP model but -Mtp not specified: use MTP build but don't enable MTP decoding
    $UseMtpBuild = $true
    Write-Info "MTP: off (add -Mtp flag to enable multi-token prediction)"
} elseif ($Mtp) {
    Write-Warn "MTP requested but model '$Model' doesn't have MTP heads - ignoring -Mtp flag"
    Write-Info "MTP: off (model doesn't support MTP)"
} else {
    Write-Info "MTP: off"
}

# Set environment for docker-compose
$env:MODEL_FILE = $ModelFile
$env:CONTEXT_SIZE = $Context.ToString()
$env:REASONING = if ($Thinking) { "on" } else { "off" }
$env:THREADS = $Threads.ToString()
$env:BATCH_SIZE = $Batch.ToString()
$env:UBATCH_SIZE = $UBatch.ToString()
$env:SPECULATIVE_FLAGS = $SpeculativeFlags
$env:MOE_FLAGS = $MoeFlags
$env:MTP_FLAGS = $MtpFlags
$env:KV_CACHE_TYPE = $KvCache
$env:EXTRA_LLAMA_FLAGS = $ExtraFlags

# Build compose command based on whether MTP build is needed
$composeFiles = @("-f", "$ScriptDir\docker-compose.yml")
if ($UseMtpBuild) {
    $composeFiles += @("-f", "$ScriptDir\docker-compose.mtp.yml")
    Write-Info "Using MTP build (am17an/llama.cpp mtp-clean branch)"
} else {
    Write-Info "Using standard build (ghcr.io/ggml-org/llama.cpp)"
}

# Always stop any running containers first (only one version should run at a time)
Write-Step "Stopping any existing containers"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    # Stop standard containers
    docker compose -f "$ScriptDir\docker-compose.yml" down 2>&1 | Out-Null
    # Stop MTP containers if MTP compose exists
    if (Test-Path "$ScriptDir\docker-compose.mtp.yml") {
        docker compose -f "$ScriptDir\docker-compose.yml" -f "$ScriptDir\docker-compose.mtp.yml" down 2>&1 | Out-Null
    }
} finally {
    $ErrorActionPreference = $prevEap
}
Write-Ok "Cleaned up"

# Build MTP image if needed and not already built
if ($UseMtpBuild) {
    $mtpImageExists = docker images -q llm-server-mtp:latest 2>$null
    if (-not $mtpImageExists) {
        Write-Step "Building MTP image (first time only, takes 10-20 minutes)..."
        Write-Host ""
        Write-Host "  NOTE: CUDA compilation in Docker on Windows can be slow or hang." -ForegroundColor Yellow
        Write-Host "  If build hangs, press Ctrl+C and run without -Mtp flag." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Building... (progress below)" -ForegroundColor Gray
        Write-Host ""
        # Stream build output in real-time so user can see progress
        docker compose @composeFiles build --progress=plain
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Failed to build MTP image"
            Write-Host ""
            Write-Info "Options:"
            Write-Info "  1. Run without MTP: .\run.ps1 -Model qwen36opus47 -MoeOffload auto -Thinking"
            Write-Info "  2. Retry the build: .\run.ps1 -Model qwen36opus47 -Mtp -Restart"
            Write-Info "  3. Check Docker Desktop has enough resources (Settings > Resources)"
            exit 1
        }
        Write-Ok "MTP image built successfully"
    }
}

# Start container
Write-Step "Starting server"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $composeOutput = docker compose @composeFiles up -d 2>&1
    $composeExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
$composeOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

if ($composeExit -ne 0) {
    Write-Err "Failed to start container"
    exit 1
}

Write-Ok "Container started"

# Wait for health check (longer timeout for MTP builds due to model loading)
Write-Host "  Waiting for server to be ready..." -ForegroundColor Gray
$timeout = if ($UseMtpBuild) { 300 } else { 180 }
$start = Get-Date
while ($true) {
    $health = docker inspect --format='{{.State.Health.Status}}' llm-server 2>$null
    if ($health -eq "healthy") {
        Write-Host ""
        Write-Ok "Server is ready!"
        break
    }
    if (((Get-Date) - $start).TotalSeconds -gt $timeout) {
        Write-Host ""
        Write-Err "Server did not become healthy within ${timeout}s"
        Write-Info "Check logs: docker compose logs"
        exit 1
    }
    Start-Sleep -Seconds 2
    Write-Host "." -NoNewline -ForegroundColor Gray
}

# Print connection info
$localIp = Get-LocalIp

Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green
Write-Host "  SERVER RUNNING" -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Local:        http://localhost:8899/v1" -ForegroundColor White
Write-Host "  LAN:          http://${localIp}:8899/v1" -ForegroundColor White
Write-Host "  Tailscale:    http://<tailscale-ip>:8899/v1" -ForegroundColor White
Write-Host ""
Write-Host "  API Key:      any-string (not validated)" -ForegroundColor Gray
Write-Host "  Container:    llm-server" -ForegroundColor Gray
Write-Host ""
Write-Host "  MacBook config:" -ForegroundColor Cyan
Write-Host "  export OPENAI_BASE_URL=http://${localIp}:8899/v1" -ForegroundColor Gray
Write-Host ""
Write-Host "  Commands:" -ForegroundColor Cyan
Write-Host "  .\run.ps1 -Stop           # Stop server" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model qwen3635ba3b # Qwen 3.6 35B-A3B" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model qwen3635ba3b2bit -MoeOffload auto # 2-bit + CPU experts" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model qwen3635ba3b4bit -MoeOffload auto -Thinking # 4-bit IQ4_XS" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model qwen36heretic -MoeOffload auto -Thinking -Mtp # Uncensored + MTP" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model qwen36opus47 -MoeOffload auto -Thinking -Mtp # Opus distill + MTP" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model gemma312 # Gemma 3 12B (after -IncludeGemma312)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model gemma426ba4b # Gemma 4 26B-A4B (after -IncludeGemma426BA4B)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -MoeOffload all # Offload ALL experts to CPU (lowest VRAM)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -MoeOffload 30  # Offload first 30 layers' experts" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Mtp -MtpTokens 8 # MTP with 8 extra tokens (MTP models only)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -KvCache q4_0   # Smaller KV cache (save VRAM)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Batch 4096 -UBatch 4096 # Higher batch for MoE" -ForegroundColor Gray
Write-Host "  .\run.ps1 -DraftModelFile <small-draft.gguf>" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Restart        # Restart server" -ForegroundColor Gray
Write-Host "  docker compose logs -f    # Stream logs" -ForegroundColor Gray
Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green

# Stream logs
Write-Host "`n[Container logs - Ctrl+C to stop streaming, server keeps running]" -ForegroundColor DarkGray
Write-Host ""

docker compose @composeFiles logs -f
