<#
.SYNOPSIS
    Idempotent setup script for local LLM server.
    Safe to run multiple times — skips completed steps.

.DESCRIPTION
    Installs prerequisites, builds llama.cpp with CUDA,
    downloads Qwen models, and configures firewall.

.PORT
    Server runs on 8899 (non-default).

.MODEL
    Primary:   Qwen3.5-9B Q4_K_M (~9 GB, 100% GPU, 90+ t/s)
    Secondary: Qwen3.5-35B-A3B UD-Q4_K_XL (~19 GB, partial GPU offload)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$EnvFile     = Join-Path $ScriptDir ".env"
$ModelsDir   = Join-Path $ScriptDir "models"
$LogsDir     = Join-Path $ScriptDir "logs"
$LlamaDir    = Join-Path $ScriptDir "llama.cpp"
$BuildDir    = Join-Path $LlamaDir "build"
$ServerExe   = Join-Path $BuildDir "bin\Release\llama-server.exe"
$ServerPort  = 8899

# ---------- helpers ----------

function Write-Step([string]$Msg) {
    Write-Host "`n=== $Msg" -ForegroundColor Cyan
}

function Write-Ok([string]$Msg) {
    Write-Host "  OK $Msg" -ForegroundColor Green
}

function Write-Skip([string]$Msg) {
    Write-Host "  -- $Msg" -ForegroundColor Yellow
}

function Write-Err([string]$Msg) {
    Write-Host "  !! $Msg" -ForegroundColor Red
}

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

function Test-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        Write-Err "This script requires Administrator privileges."
        Write-Host "  Right-click PowerShell -> 'Run as Administrator'"
        exit 1
    }
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

# ---------- Step 1: Prerequisites ----------

Write-Step "Step 1: Checking prerequisites"

$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Err "winget not found. Install App Installer from Microsoft Store."
    exit 1
}

function Install-WinGet-Package([string]$Id, [string]$Name, [string]$CheckCmd) {
    $exists = Invoke-Expression "$CheckCmd -ErrorAction SilentlyContinue"
    if ($exists) {
        Write-Skip "$Name already installed"
        return
    }
    Write-Host "  Installing $Name via winget..."
    winget install --id $Id --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
    $env:PATH = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    Write-Ok "$Name installed"
}

Install-WinGet-Package "Kitware.CMake" "CMake" "Get-Command cmake"
Install-WinGet-Package "Git.Git"       "Git"    "Get-Command git"
Install-WinGet-Package "Python.Python.3.12" "Python 3.12" "Get-Command python"

# Git LFS
$gitLfs = git lfs version 2>$null
if (-not $gitLfs) {
    Write-Host "  Installing Git LFS..."
    git lfs install 2>&1 | Out-Null
    Write-Ok "Git LFS installed"
} else {
    Write-Skip "Git LFS already installed ($gitLfs)"
}

# Python packages
$pipInstalled = pip show huggingface_hub 2>$null
if (-not $pipInstalled) {
    Write-Host "  Installing huggingface_hub..."
    pip install --upgrade huggingface_hub 2>&1 | Out-Null
    Write-Ok "huggingface_hub installed"
} else {
    Write-Skip "huggingface_hub already installed"
}

# ---------- Step 2: CUDA ----------

Write-Step "Step 2: Checking CUDA"

$nvcc = Get-Command nvcc -ErrorAction SilentlyContinue
if ($nvcc) {
    $cudaVersion = & nvcc --version 2>$null | Select-String "release (\d+\.\d+)" | ForEach-Object { $_.Matches.Groups[1].Value }
    Write-Host "  Found CUDA $cudaVersion"

    $major = [int]($cudaVersion.Split(".")[0])
    if ($major -lt 12) {
        Write-Host "  CUDA 11.x detected. Upgrading to CUDA 12.x for best performance..."
        Write-Host "  Installing CUDA Toolkit 12.6 via winget..."
        winget install --id "NVIDIA.CUDA.12.6" --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
        $env:PATH = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        Write-Ok "CUDA 12.6 installed. Open a NEW PowerShell window for PATH to take effect."
    } else {
        Write-Ok "CUDA $cudaVersion - good to go"
    }
} else {
    Write-Host "  CUDA not found. Installing CUDA Toolkit 12.6..."
    Require-Admin
    winget install --id "NVIDIA.CUDA.12.6" --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
    $env:PATH = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    Write-Ok "CUDA 12.6 installed. Open a NEW PowerShell window for PATH to take effect."
    Write-Host "  IMPORTANT: Re-run this setup script in a new PowerShell window."
    exit 0
}

# ---------- Step 3: Clone llama.cpp ----------

Write-Step "Step 3: Setting up llama.cpp"

if (Test-Path (Join-Path $LlamaDir ".git")) {
    Write-Host "  Pulling latest llama.cpp..."
    Push-Location $LlamaDir
    git pull --rebase 2>&1 | Out-Null
    Pop-Location
    Write-Ok "llama.cpp updated"
} else {
    if (Test-Path $LlamaDir) {
        Write-Host "  Removing stale llama.cpp directory..."
        Remove-Item $LlamaDir -Recurse -Force
    }
    Write-Host "  Cloning llama.cpp..."
    git clone https://github.com/ggml-org/llama.cpp $LlamaDir 2>&1 | Out-Null
    Write-Ok "llama.cpp cloned"
}

# ---------- Step 4: Build llama.cpp ----------

Write-Step "Step 4: Building llama.cpp with CUDA"

if (Test-Path $ServerExe) {
    $age = (Get-Item $ServerExe).LastWriteTime
    $daysOld = ((Get-Date) - $age).Days
    if ($daysOld -lt 7) {
        Write-Skip "llama-server.exe exists (built $daysOld days ago), skipping build"
        Write-Host "  Delete $LlamaDir\build to force rebuild"
    } else {
        Write-Host "  Build is $daysOld days old, rebuilding..."
        Remove-Item $BuildDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path $ServerExe)) {
    Write-Host "  Configuring cmake..."
    cmake -B $BuildDir -S $LlamaDir -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release 2>&1 | Out-Null
    Write-Host "  Building (this takes 5-15 minutes)..."
    cmake --build $BuildDir --config Release --parallel 2>&1 | Out-Null

    if (-not (Test-Path $ServerExe)) {
        Write-Err "Build failed - llama-server.exe not found"
        Write-Host "  Check cmake output above for errors"
        exit 1
    }
    Write-Ok "llama-server.exe built at $ServerExe"
}

# ---------- Step 5: Download Models ----------

Write-Step "Step 5: Downloading models"

$token = Get-HfToken
$env:HF_TOKEN = $token

function Download-Model([string]$Repo, [string]$Include, [string]$Name) {
    $existing = Get-ChildItem $ModelsDir -Filter $Include -ErrorAction SilentlyContinue
    if ($existing) {
        $sizeGB = [math]::Round($existing[0].Length / 1GB, 2)
        Write-Skip "$Name already exists ($sizeGB GB)"
        return
    }
    Write-Host "  Downloading $Name from $Repo ..."
    Write-Host "  (This may take a while depending on your connection)"
    huggingface-cli download $Repo --include $Include --local-dir $ModelsDir --token $token
    $downloaded = Get-ChildItem $ModelsDir -Filter $Include -ErrorAction SilentlyContinue
    if ($downloaded) {
        $sizeGB = [math]::Round($downloaded[0].Length / 1GB, 2)
        Write-Ok "$Name downloaded ($sizeGB GB)"
    } else {
        Write-Err "$Name download failed"
    }
}

# Primary: Qwen3.5-9B Q4_K_M (~9 GB, 100% GPU)
Download-Model "unsloth/Qwen3.5-9B-GGUF" "*Q4_K_M*" "Qwen3.5-9B Q4_K_M"

# Secondary: Qwen3.5-35B-A3B UD-Q4_K_XL (~19 GB)
Download-Model "unsloth/Qwen3.5-35B-A3B-GGUF" "*Q4_K_XL*" "Qwen3.5-35B-A3B UD-Q4_K_XL"

# ---------- Step 6: Firewall ----------

Write-Step "Step 6: Configuring Windows Firewall"

Require-Admin

$ruleName = "LLM Server Port $ServerPort"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

if ($existingRule) {
    Write-Skip "Firewall rule '$ruleName' already exists"
} else {
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $ServerPort `
        -Action Allow `
        -Profile Any `
        -Enabled True | Out-Null
    Write-Ok "Firewall rule created for port $ServerPort"
}

# ---------- Done ----------

Write-Step "Setup Complete"
Write-Host ""
Write-Host "  Primary model:   Qwen3.5-9B Q4_K_M (~9 GB)" -ForegroundColor White
Write-Host "  Secondary model: Qwen3.5-35B-A3B UD-Q4_K_XL (~19 GB)" -ForegroundColor White
Write-Host "  Server port:     $ServerPort" -ForegroundColor White
Write-Host "  Server binary:   $ServerExe" -ForegroundColor White
Write-Host ""
Write-Host "  Run the server:" -ForegroundColor Cyan
Write-Host "  .\run.ps1                  # Start with primary model" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model 35b       # Start with 35B MoE model" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Restart         # Restart server" -ForegroundColor Gray
Write-Host ""
