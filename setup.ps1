<#
.SYNOPSIS
    Idempotent setup script for Docker-based LLM server.
    Safe to run multiple times - skips completed steps.

.DESCRIPTION
    Installs Docker Desktop, verifies GPU access, pulls the llama.cpp
    server image, downloads Qwen3.5-9B (default) to HuggingFace cache and links
    to models/ for Docker access, and configures firewall.

.PARAMETER IncludeQwen3635ba3b
    Also download Qwen3.6-35B-A3B UD-Q4_K_S (~21 GB). MoE model, good with -MoeOffload.

.PARAMETER IncludeQwen3Uncensored8b
    Also download Qwen3-8B-Uncensor-v2 Q4_K_M (~5 GB). Uncensored 8B variant.

.PARAMETER IncludeQwen36Q2
    Also download Qwen3.6-35B-A3B-UD-Q2_K_XL (2-bit quant, ~13 GB, fits more context in VRAM).

.PARAMETER IncludeQwen36IQ4
    Also download Qwen3.6-35B-A3B IQ4_XS (4-bit imatrix quant, ~14 GB).

.PARAMETER IncludeQwen36Heretic
    Also download Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved Q4_K_M (~22 GB).
    Uncensored model with native Multi-Token Prediction (MTP) support.

.PARAMETER IncludeQwen36Opus47
    Also download lordx64-Qwen3.6-35B-A3B-Claude-4.7-Opus-Reasoning-Distilled-MTP Q4_K_M (~20 GB).
    Claude 4.7 Opus reasoning distillation with native MTP support. Best for code/reasoning.

.PARAMETER IncludeGemma312
    Also download Gemma 3 12B IT Q4_K_M (~7 GB).

.PARAMETER IncludeGemma426BA4B
    Also download Gemma 4 26B-A4B IT UD-Q4_K_M (~16 GB). MoE model.

.PARAMETER Model
    Shorthand for -Include* switches. Accepts: 35b, qwen3uncensored8b, qwen3635ba3b2bit, qwen3635ba3b4bit, qwen36heretic, qwen36opus47, gemma312, gemma426ba4b.
#>

param(
    [switch]$IncludeQwen3635ba3b,

    [switch]$IncludeQwen3Uncensored8b,

    [switch]$IncludeQwen36Q2,

    [switch]$IncludeQwen36IQ4,

    [switch]$IncludeQwen36Heretic,

    [switch]$IncludeQwen36Opus47,

    [switch]$IncludeGemma312,

    [switch]$IncludeGemma426BA4B,

    [string]$Model
)

$ErrorActionPreference = "Stop"

# Map -Model to -Include* (same names as run.ps1)
$downloadQwen3635ba3b = [bool]$IncludeQwen3635ba3b
$downloadQwen3Uncensored8b = [bool]$IncludeQwen3Uncensored8b
$downloadQwen36Q2 = [bool]$IncludeQwen36Q2
$downloadQwen36IQ4 = [bool]$IncludeQwen36IQ4
$downloadQwen36Heretic = [bool]$IncludeQwen36Heretic
$downloadQwen36Opus47 = [bool]$IncludeQwen36Opus47
$downloadGemma312 = [bool]$IncludeGemma312
$downloadGemma426BA4B = [bool]$IncludeGemma426BA4B

if ($PSBoundParameters.ContainsKey("Model") -and -not [string]::IsNullOrWhiteSpace($Model)) {
    $m = $Model.Trim()
    if ($m -eq "35b" -or $m -eq "qwen3635ba3b") {
        $downloadQwen3635ba3b = $true
    } elseif ($m -eq "qwen3uncensored8b") {
        $downloadQwen3Uncensored8b = $true
    } elseif ($m -eq "qwen3635ba3b2bit") {
        $downloadQwen36Q2 = $true
    } elseif ($m -eq "qwen3635ba3b4bit") {
        $downloadQwen36IQ4 = $true
    } elseif ($m -eq "qwen36heretic") {
        $downloadQwen36Heretic = $true
    } elseif ($m -eq "qwen36opus47") {
        $downloadQwen36Opus47 = $true
    } elseif ($m -eq "gemma312") {
        $downloadGemma312 = $true
    } elseif ($m -eq "gemma426ba4b") {
        $downloadGemma426BA4B = $true
    } else {
        Write-Host "  !! setup.ps1 -Model accepts: 35b, qwen3uncensored8b, qwen3635ba3b2bit, qwen3635ba3b4bit, qwen36heretic, qwen36opus47, gemma312, gemma426ba4b" -ForegroundColor Red
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

# Show HF cache location
$hfHome = if ($env:HF_HOME) { $env:HF_HOME } else { Join-Path $env:USERPROFILE ".cache\huggingface" }
Write-Host "  -> HF cache: $hfHome" -ForegroundColor Gray

function Download-Model([string]$Repo, [string]$Pattern, [string]$Name) {
    $existing = Get-ChildItem $ModelsDir -Filter $Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        $sizeGB = [math]::Round($existing.Length / 1GB, 2)
        Write-Skip "$Name already exists ($sizeGB GB)"
        return
    }
    Write-Host "  Downloading $Name from $Repo to HF cache..."
    Write-Host "  (This may take a while depending on your connection; progress shown below)"
    
    # Download to HF cache and return the cached file path
    $pyScript = @"
import os
import fnmatch
import warnings
warnings.filterwarnings('ignore')
from huggingface_hub import HfApi, hf_hub_download

repo_id = '$Repo'
pattern = '$Pattern'
token = os.environ.get('HF_TOKEN')

api = HfApi(token=token)
repo_files = api.list_repo_files(repo_id=repo_id, repo_type='model')
matches = [f for f in repo_files if fnmatch.fnmatch(f, pattern)]
if not matches:
    raise RuntimeError(f'No file matching pattern {pattern!r} in {repo_id}')

# Download to HF cache (default behavior without local_dir)
target_file = matches[0]
cached_path = hf_hub_download(
    repo_id=repo_id,
    filename=target_file,
    token=token,
    repo_type='model',
    resume_download=True,
)
print('CACHED_PATH:' + cached_path)
print('FILENAME:' + os.path.basename(target_file))
"@
    
    $pyScriptFile = Join-Path $env:TEMP "hf_download.py"
    $pyScript | Out-File -FilePath $pyScriptFile -Encoding utf8
    
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & python $pyScriptFile 2>&1 | Tee-Object -Variable capturedOutput
        $pyExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    Remove-Item $pyScriptFile -Force -ErrorAction SilentlyContinue
    
    if ($pyExit -eq 0) {
        # Parse cached path and filename from output
        $outputLines = $capturedOutput | ForEach-Object { $_.ToString() }
        $cachedPath = ($outputLines | Where-Object { $_ -match '^CACHED_PATH:' } | Select-Object -First 1) -replace '^CACHED_PATH:', ''
        $filename = ($outputLines | Where-Object { $_ -match '^FILENAME:' } | Select-Object -First 1) -replace '^FILENAME:', ''
        
        if ($cachedPath -and (Test-Path $cachedPath)) {
            $linkPath = Join-Path $ModelsDir $filename
            $cachedSize = [math]::Round((Get-Item $cachedPath).Length / 1GB, 2)
            
            # Create symlink in models/ pointing to HF cache
            if (Test-Path $linkPath) {
                Remove-Item $linkPath -Force
            }
            
            try {
                # Try symlink first (requires admin or dev mode on Windows)
                New-Item -ItemType SymbolicLink -Path $linkPath -Target $cachedPath -ErrorAction Stop | Out-Null
                Write-Ok "$Name cached ($cachedSize GB) - symlinked to models/"
            } catch {
                # Fall back to hardlink (works for files without admin)
                try {
                    New-Item -ItemType HardLink -Path $linkPath -Target $cachedPath -ErrorAction Stop | Out-Null
                    Write-Ok "$Name cached ($cachedSize GB) - hardlinked to models/"
                } catch {
                    # Last resort: copy the file
                    Write-Warn "Cannot create link (enable Developer Mode for symlinks). Copying instead..."
                    Copy-Item $cachedPath $linkPath
                    Write-Ok "$Name cached ($cachedSize GB) - copied to models/"
                }
            }
        } else {
            Write-Err "$Name download completed but cached file not found"
        }
    } else {
        Write-Err "$Name download failed"
    }
}

# Default: always download 9B
Download-Model "unsloth/Qwen3.5-9B-GGUF" "*Q4_K_M*" "Qwen3.5-9B Q4_K_M"

# Optional models
if ($downloadQwen3635ba3b) {
    Download-Model "unsloth/Qwen3.6-35B-A3B-GGUF" "Qwen3.6-35B-A3B-UD-Q4_K_S.gguf" "Qwen3.6-35B-A3B UD-Q4_K_S"
}
if ($downloadQwen3Uncensored8b) {
    Download-Model "mradermacher/Qwen3-8B-Uncensor-v2-GGUF" "*Q4_K_M*.gguf" "Qwen3-8B-Uncensor-v2 Q4_K_M"
}
if ($downloadQwen36Q2) {
    Download-Model "unsloth/Qwen3.6-35B-A3B-GGUF" "Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf" "Qwen3.6-35B-A3B UD-Q2_K_XL (2-bit)"
}
if ($downloadQwen36IQ4) {
    Download-Model "unsloth/Qwen3.6-35B-A3B-GGUF" "*IQ4_XS*" "Qwen3.6-35B-A3B IQ4_XS (4-bit)"
}
if ($downloadGemma312) {
    Download-Model "unsloth/gemma-3-12b-it-GGUF" "gemma-3-12b-it-Q4_K_M.gguf" "Gemma 3 12B IT Q4_K_M"
}
if ($downloadGemma426BA4B) {
    Download-Model "unsloth/gemma-4-26B-A4B-it-GGUF" "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" "Gemma 4 26B-A4B IT UD-Q4_K_M"
}
if ($downloadQwen36Heretic) {
    Download-Model "llmfan46/Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-GGUF" "Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-Q4_K_M.gguf" "Qwen3.6-35B-A3B Uncensored Heretic MTP Q4_K_M"
}
if ($downloadQwen36Opus47) {
    Download-Model "Dyluhn/lordx64-Qwen3.6-35B-A3B-Claude-4.7-Opus-Reasoning-Distilled-MTP-GGUF" "lordx64-distill-MTP-Q4_K_M.gguf" "Qwen3.6-35B-A3B Claude Opus Distill MTP Q4_K_M"
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
Write-Host "  Docker image:  ghcr.io/ggml-org/llama.cpp:server-cuda" -ForegroundColor White
Write-Host "  Default model: Qwen3.5-9B Q4_K_M (~5 GB)" -ForegroundColor White
if ($downloadQwen3635ba3b) {
    Write-Host "  + Qwen3.6-35B-A3B UD-Q4_K_S (~21 GB)" -ForegroundColor White
}
if ($downloadQwen3Uncensored8b) {
    Write-Host "  + Qwen3-8B-Uncensor-v2 Q4_K_M (~5 GB)" -ForegroundColor White
}
if ($downloadQwen36Q2) {
    Write-Host "  + Qwen3.6-35B-A3B UD-Q2_K_XL (~13 GB)" -ForegroundColor White
}
if ($downloadQwen36IQ4) {
    Write-Host "  + Qwen3.6-35B-A3B IQ4_XS (~14 GB)" -ForegroundColor White
}
if ($downloadQwen36Heretic) {
    Write-Host "  + Qwen3.6-35B-A3B Uncensored Heretic MTP (~22 GB)" -ForegroundColor White
}
if ($downloadQwen36Opus47) {
    Write-Host "  + Qwen3.6-35B-A3B Claude Opus Distill MTP (~20 GB)" -ForegroundColor White
}
if ($downloadGemma312) {
    Write-Host "  + Gemma 3 12B IT Q4_K_M (~7 GB)" -ForegroundColor White
}
if ($downloadGemma426BA4B) {
    Write-Host "  + Gemma 4 26B-A4B IT UD-Q4_K_M (~16 GB)" -ForegroundColor White
}
Write-Host "  Server port:   $ServerPort" -ForegroundColor White
Write-Host ""
Write-Host "  Download additional models:" -ForegroundColor Cyan
Write-Host "  .\setup.ps1 -IncludeQwen3635ba3b       # 35B MoE (~21 GB)" -ForegroundColor Gray
Write-Host "  .\setup.ps1 -IncludeQwen3Uncensored8b  # Uncensored 8B (~5 GB)" -ForegroundColor Gray
Write-Host "  .\setup.ps1 -IncludeQwen36Heretic      # Uncensored 35B + MTP (~22 GB)" -ForegroundColor Gray
Write-Host "  .\setup.ps1 -IncludeQwen36Opus47       # Opus distill + MTP (~20 GB)" -ForegroundColor Gray
Write-Host "  .\setup.ps1 -IncludeGemma312           # Gemma 3 12B (~7 GB)" -ForegroundColor Gray
Write-Host "  .\setup.ps1 -IncludeGemma426BA4B       # Gemma 4 26B-A4B MoE (~16 GB)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Run the server:" -ForegroundColor Cyan
Write-Host "  .\run.ps1                      # 9B (default)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model 35b           # 35B MoE" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model qwen36opus47 -Mtp -Thinking  # Opus + MTP" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model qwen36heretic -Mtp -Thinking # Uncensored + MTP" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model qwen36opus47 -Tbq4           # TBQ4 fused FA (~25% faster)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Thinking            # Enable reasoning mode" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Mtp             # Enable Multi-Token Prediction (MTP models only)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Restart         # Restart server" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Stop            # Stop server" -ForegroundColor Gray
Write-Host ""
