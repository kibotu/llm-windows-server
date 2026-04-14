<#
.SYNOPSIS
    Idempotent setup script for Docker-based LLM server.
    Safe to run multiple times - skips completed steps.

.DESCRIPTION
    Installs Docker Desktop, verifies GPU access, pulls the llama.cpp
    server image, downloads Qwen models, and configures firewall.

.PARAMETER IncludeGemma312
    Also download Gemma 3 12B IT Q4_K_M from unsloth/gemma-3-12b-it-GGUF (~7 GB, good for 16 GB VRAM).

.PARAMETER IncludeGemma426BA4B
    Also download Gemma 4 26B-A4B IT UD-Q4_K_M from unsloth/gemma-4-26B-A4B-it-GGUF (~16-17 GB).

.PARAMETER Model
    Optional. gemma312 / gemma426ba4b mirror the -Include* switches. Qwen models always download.
#>

param(
    [switch]$IncludeGemma312,

    [switch]$IncludeGemma426BA4B,

    [string]$Model
)

$ErrorActionPreference = "Stop"

# Map -Model to -Include* (same names as run.ps1)
$downloadGemma312 = [bool]$IncludeGemma312
$downloadGemma426BA4B = [bool]$IncludeGemma426BA4B
if ($PSBoundParameters.ContainsKey("Model") -and -not [string]::IsNullOrWhiteSpace($Model)) {
    $m = $Model.Trim()
    if ($m -eq "gemma312") {
        $downloadGemma312 = $true
    } elseif ($m -eq "gemma426ba4b") {
        $downloadGemma426BA4B = $true
    } else {
        Write-Err "setup.ps1 -Model only accepts 'gemma312' or 'gemma426ba4b'."
        Write-Host "  To run the server: .\run.ps1 -Model 9b | 35b | gemma312 | gemma426ba4b" -ForegroundColor Yellow
        exit 1
    }
}
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
$EnvFile = Join-Path $ScriptDir ".env"
$ModelsDir = Join-Path $ScriptDir "models"
$LogsDir = Join-Path $ScriptDir "logs"
$ServerPort = 8899

function Write-Step([string]$Msg) { Write-Host "`n=== $Msg" -ForegroundColor Cyan }
function Write-Ok([string]$Msg) { Write-Host "  OK $Msg" -ForegroundColor Green }
function Write-Skip([string]$Msg) { Write-Host "  -- $Msg" -ForegroundColor Yellow }
function Write-Err([string]$Msg) { Write-Host "  !! $Msg" -ForegroundColor Red }

function Get-HfToken {
    if (-not (Test-Path $EnvFile)) {
        Write-Err ".env file not found at $EnvFile"
        Write-Host "  Create it with: HF_TOKEN=your_token"
        exit 1
    }
    $content = Get-Content $EnvFile -Raw
    $match = [regex]::Match($content, 'HF_TOKEN\s*=\s*(.+)')
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups[1].Value.Trim())) {
        Write-Err "HF_TOKEN not found in .env"
        exit 1
    }
    return $match.Groups[1].Value.Trim()
}

# ---------- Step 0: Directories ----------

Write-Step "Step 0: Creating directories"
foreach ($dir in @($ModelsDir, $LogsDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Ok "Created $dir"
    } else {
        Write-Skip "$dir already exists"
    }
}

# ---------- Step 1: Docker Desktop ----------

Write-Step "Step 1: Checking Docker Desktop"

$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) {
    Write-Host "  Docker not found, installing via winget..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Err "winget not found. Install Docker Desktop manually from https://docker.com/products/docker-desktop"
        exit 1
    }
    winget install --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
    Write-Host ""
    Write-Err "Docker Desktop installed. Please:"
    Write-Host "  1. Restart your computer (required for WSL2 integration)"
    Write-Host "  2. Launch Docker Desktop and complete initial setup"
    Write-Host "  3. Re-run this script"
    exit 0
} else {
    Write-Skip "Docker already installed"
}

# Check if Docker is running
$dockerInfo = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Starting Docker Desktop..."
    
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
            break
        }
        if (((Get-Date) - $start).TotalSeconds -gt $timeout) {
            Write-Err "Docker Desktop failed to start within ${timeout}s"
            Write-Host "  Please start Docker Desktop manually and re-run this script"
            exit 1
        }
        Write-Host "." -NoNewline -ForegroundColor Gray
    }
    Write-Host ""
} else {
    Write-Skip "Docker Desktop is running"
}

# ---------- Step 2: GPU Access ----------

Write-Step "Step 2: Verifying GPU access in Docker"

Write-Host "  Testing NVIDIA GPU access (pulling nvidia/cuda test image if needed)..."
# Docker writes pull progress to stderr; $ErrorActionPreference Stop would otherwise abort on that noise.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $gpuTest = docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi 2>&1 | Out-String
    $gpuExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
if ($gpuExit -ne 0) {
    Write-Err "GPU access failed. Ensure:"
    Write-Host "  1. NVIDIA drivers are installed (run 'nvidia-smi' in PowerShell)"
    Write-Host "  2. Docker Desktop has WSL2 backend enabled"
    Write-Host "  3. Docker Desktop > Settings > Resources > WSL Integration is enabled"
    Write-Host "  4. Try manually: docker pull nvidia/cuda:12.4.0-base-ubuntu22.04"
    Write-Host ""
    Write-Host "  Error: $gpuTest"
    exit 1
}

$gpuName = $gpuTest -split "`n" | Select-String "NVIDIA" | Select-Object -First 1
$gpuLine = if ($gpuName) { $gpuName.ToString().Trim() } else { "nvidia-smi exited 0" }
Write-Ok "GPU accessible: $gpuLine"

# ---------- Step 3: Pull Image ----------

Write-Step "Step 3: Pulling llama.cpp server image"

$imageName = "ghcr.io/ggml-org/llama.cpp:server-cuda"
$imageExists = docker images -q $imageName 2>$null
if ($imageExists) {
    Write-Skip "Image already pulled: $imageName"
    Write-Host "  Run 'docker pull $imageName' to update"
} else {
    Write-Host "  Pulling $imageName (this may take a few minutes)..."
    docker pull $imageName
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to pull image"
        exit 1
    }
    Write-Ok "Image pulled successfully"
}

# ---------- Step 4: Download Models ----------

Write-Step "Step 4: Downloading models"

$token = Get-HfToken
$env:HF_TOKEN = $token

# Ensure huggingface_hub is installed
$hfCheck = python -c "import huggingface_hub" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Installing huggingface_hub..."
    python -m pip install huggingface_hub --quiet
}

function Download-Model([string]$Repo, [string]$Pattern, [string]$Name) {
    $existing = Get-ChildItem $ModelsDir -Filter $Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        $sizeGB = [math]::Round($existing.Length / 1GB, 2)
        Write-Skip "$Name already exists ($sizeGB GB)"
        return
    }
    Write-Host "  Downloading $Name from $Repo..."
    Write-Host "  (This may take a while depending on your connection)"
    
    $pyScript = @"
import os
import warnings
warnings.filterwarnings('ignore')
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='$Repo',
    allow_patterns=['$Pattern'],
    local_dir=r'$ModelsDir',
    token=os.environ.get('HF_TOKEN')
)
print('DOWNLOAD_SUCCESS')
"@
    
    $pyScriptFile = Join-Path $env:TEMP "hf_download.py"
    $pyScript | Out-File -FilePath $pyScriptFile -Encoding utf8
    
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $result = & python $pyScriptFile 2>&1
        $pyExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    Remove-Item $pyScriptFile -Force -ErrorAction SilentlyContinue
    
    $resultText = $result | Out-String
    if ($pyExit -eq 0 -and $resultText -match "DOWNLOAD_SUCCESS") {
        $downloaded = Get-ChildItem $ModelsDir -Filter $Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($downloaded) {
            $sizeGB = [math]::Round($downloaded.Length / 1GB, 2)
            Write-Ok "$Name downloaded ($sizeGB GB)"
        } else {
            Write-Err "$Name download completed but file not found"
        }
    } else {
        Write-Host "  $resultText" -ForegroundColor Yellow
        Write-Err "$Name download failed"
    }
}

Download-Model "unsloth/Qwen3.5-9B-GGUF" "*Q4_K_M*" "Qwen3.5-9B Q4_K_M"
Download-Model "unsloth/Qwen3.5-35B-A3B-GGUF" "*Q4_K_XL*" "Qwen3.5-35B-A3B UD-Q4_K_XL"

if ($downloadGemma312) {
    Download-Model "unsloth/gemma-3-12b-it-GGUF" "gemma-3-12b-it-Q4_K_M.gguf" "Gemma 3 12B IT Q4_K_M"
}
if ($downloadGemma426BA4B) {
    Download-Model "unsloth/gemma-4-26B-A4B-it-GGUF" "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" "Gemma 4 26B-A4B IT UD-Q4_K_M"
}

# ---------- Step 5: Firewall ----------

Write-Step "Step 5: Configuring Windows Firewall"

$ruleName = "LLM Server Port $ServerPort"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

if ($existingRule) {
    Write-Skip "Firewall rule '$ruleName' already exists"
} else {
    try {
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $ServerPort `
            -Action Allow `
            -Profile Any `
            -Enabled True | Out-Null
        Write-Ok "Firewall rule created for port $ServerPort"
    } catch {
        Write-Skip "Could not create firewall rule (need admin). Run as Administrator if remote access needed."
    }
}

# ---------- Done ----------

Write-Step "Setup Complete"
Write-Host ""
Write-Host "  Docker image:    ghcr.io/ggml-org/llama.cpp:server-cuda" -ForegroundColor White
Write-Host "  Primary model:   Qwen3.5-9B Q4_K_M" -ForegroundColor White
Write-Host "  Secondary model: Qwen3.5-35B-A3B UD-Q4_K_XL" -ForegroundColor White
if ($downloadGemma312) {
    Write-Host "  Optional model:  Gemma 3 12B IT Q4_K_M (16 GB VRAM friendly)" -ForegroundColor White
}
if ($downloadGemma426BA4B) {
    Write-Host "  Optional model:  Gemma 4 26B-A4B IT UD-Q4_K_M (~16-17 GB)" -ForegroundColor White
}
Write-Host "  Server port:     $ServerPort" -ForegroundColor White
Write-Host ""
Write-Host "  ~16 GB VRAM (e.g. RTX 4080) - Unsloth single-file GGUF:" -ForegroundColor Cyan
Write-Host "  .\setup.ps1 -IncludeGemma312  # or -Model gemma312  (~7 GB)" -ForegroundColor Gray
Write-Host "  .\setup.ps1 -IncludeGemma426BA4B # or -Model gemma426ba4b (~16-17 GB)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Run the server:" -ForegroundColor Cyan
Write-Host "  .\run.ps1                  # Start with 9B model" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model 35b       # Start with 35B MoE model" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model gemma312  # Gemma 3 12B IT" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model gemma426ba4b # Gemma 4 26B-A4B IT" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Restart         # Restart server" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Stop            # Stop server" -ForegroundColor Gray
Write-Host ""
