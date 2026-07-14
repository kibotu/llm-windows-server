<#
.SYNOPSIS
    One-stop setup + update for the Docker-based llama.cpp LLM server.

.DESCRIPTION
    Idempotent. Safe to run any number of times - the first run installs
    everything, later runs update it. Each step is skipped if already done.

      1. Docker Desktop        install (winget) + start
      2. GPU access            verify NVIDIA runtime inside Docker
      3. Hugging Face CLI      install/upgrade latest 'hf' + login from .env
      4. Server API key        generate a random key into .env (if missing)
      5. llama.cpp image       pull the latest image tag from docker-compose.yml
      6. usage-tracker proxy   (re)build from this repo's Dockerfile
      7. Model                 download GGUF + vision projector into .\models\
      8. Firewall              open the server port for LAN access
      9. Cleanup               prune dangling Docker layers (models untouched)

.PARAMETER Model
    Which model to ensure is downloaded: "qwen36" (default) or "qwen35-9b".

.PARAMETER SkipModel
    Skip the model download step (just refresh Docker + tooling).

.PARAMETER Clean
    Aggressive cleanup: remove ALL unused images, not just dangling layers.

.EXAMPLE
    .\setup.ps1                     # full setup / update with the default model
    .\setup.ps1 -Model qwen35-9b    # also fetch the lighter 9B model
    .\setup.ps1 -SkipModel          # update Docker + tooling only
    .\setup.ps1 -Clean              # update and reclaim disk aggressively
#>

[CmdletBinding()]
param(
    [ValidateSet("qwen36", "qwen35-9b")]
    [string]$Model = "qwen36",

    [switch]$SkipModel,

    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
try { 
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch { }

# =============================================================================
# MODEL CATALOG (must match run.ps1)
# =============================================================================
$Models = @{
    "qwen36" = @{
        Repo          = "unsloth/Qwen3.6-35B-A3B-GGUF"
        File          = "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"
        Include       = "*UD-IQ4_XS*"
        MmprojRepo    = "unsloth/Qwen3.6-35B-A3B-GGUF"
        MmprojFile    = "Qwen3.6-35B-A3B-mmproj-BF16.gguf"
        MmprojInclude = "*mmproj-BF16*"
        Label         = "Qwen3.6-35B-A3B IQ4_XS (vision, MoE, ~17 GB)"
    }
    "qwen35-9b" = @{
        Repo          = "unsloth/Qwen3.5-9B-GGUF"
        File          = "Qwen3.5-9B-Q4_K_M.gguf"
        Include       = "*Q4_K_M*"
        MmprojRepo    = "unsloth/Qwen3.5-9B-GGUF"
        MmprojFile    = "Qwen3.5-9B-mmproj-BF16.gguf"
        MmprojInclude = "*mmproj-BF16*"
        Label         = "Qwen3.5-9B Q4_K_M (vision, dense, ~5 GB)"
    }
}

# =============================================================================
# TUI
# =============================================================================
$script:Step = 0
$script:StepTotal = 9
$EnvFile   = Join-Path $ScriptDir ".env"
$ModelsDir = Join-Path $ScriptDir "models"
$LogsDir   = Join-Path $ScriptDir "logs"
$ServerPort = 8899

function Write-Banner {
    param([string]$Title, [string]$Subtitle)
    $w = 62
    $top = "+" + ("-" * ($w - 2)) + "+"
    Write-Host ""
    Write-Host $top -ForegroundColor DarkCyan
    Write-Host ("|" + (" $Title".PadRight($w - 2)) + "|") -ForegroundColor Cyan
    if ($Subtitle) { Write-Host ("|" + (" $Subtitle".PadRight($w - 2)) + "|") -ForegroundColor DarkGray }
    Write-Host $top -ForegroundColor DarkCyan
}
function Write-Step {
    param([string]$Msg)
    $script:Step++
    Write-Host ""
    Write-Host ("  [{0}/{1}] " -f $script:Step, $script:StepTotal) -ForegroundColor Cyan -NoNewline
    Write-Host $Msg -ForegroundColor White
}
function Write-Ok   { param([string]$m) Write-Host "        [ok]   $m" -ForegroundColor Green }
function Write-Skip { param([string]$m) Write-Host "        [skip] $m" -ForegroundColor DarkGray }
function Write-Info { param([string]$m) Write-Host "        [..]   $m" -ForegroundColor Gray }
function Write-Warn { param([string]$m) Write-Host "        [warn] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "        [err]  $m" -ForegroundColor Red }

# =============================================================================
# HELPERS
# =============================================================================
function Get-DotEnvValue {
    param([string]$Key)
    if (-not (Test-Path $EnvFile)) { return $null }
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$Key\s*=\s*(.+)$" } | Select-Object -First 1
    if ($line -and $line -match "^\s*$Key\s*=\s*(.+)$") { return $Matches[1].Trim() }
    return $null
}

function Set-DotEnvValue {
    param([string]$Key, [string]$Value)
    $lines = if (Test-Path $EnvFile) { @(Get-Content $EnvFile) } else { @() }
    $found = $false
    $out = foreach ($l in $lines) {
        if ($l -match "^\s*$Key\s*=") { $found = $true; "$Key=$Value" } else { $l }
    }
    if (-not $found) { $out = @($out) + "$Key=$Value" }
    [System.IO.File]::WriteAllText($EnvFile, (($out -join "`r`n") + "`r`n"))
}

function New-ApiKey {
    $bytes = New-Object 'System.Byte[]' 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return "sk-" + ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
}

function Add-DockerToPath {
    if (Get-Command docker -ErrorAction SilentlyContinue) { return }
    $bin = @("D:\Docker\resources\bin", "C:\Program Files\Docker\Docker\resources\bin") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($bin) { $env:PATH = "$bin;$env:PATH" }
}

function Start-DockerDesktop {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Info "Docker daemon not responding, launching Docker Desktop..."
    $exe = @("D:\Docker\Docker Desktop.exe", "C:\Program Files\Docker\Docker\Docker Desktop.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { return $false }
    Start-Process $exe -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $null = docker info 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ""
    return $false
}

function Get-HfCommand {
    $hf = Get-Command hf -ErrorAction SilentlyContinue
    if (-not $hf) { $hf = Get-Command huggingface-cli -ErrorAction SilentlyContinue }
    return $hf
}

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    Push-Location $ScriptDir
    try {
        & docker compose @ComposeArgs
        if ($LASTEXITCODE -ne 0) { throw "docker compose $($ComposeArgs -join ' ') failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
}

function Get-ModelFromHub {
    param([string]$Repo, [string]$Include, [string]$DestFile, [string]$Label)

    $destPath = Join-Path $ModelsDir $DestFile
    if (Test-Path $destPath) {
        $gb = [math]::Round((Get-Item $destPath).Length / 1GB, 2)
        Write-Skip "$Label already present ($gb GB)"
        return
    }

    Write-Info "Downloading $Label from $Repo ..."
    $hf = Get-HfCommand
    $tmp = Join-Path $env:TEMP ("hf_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $env:HF_HUB_ENABLE_HF_TRANSFER = "1"

    & $hf.Name download $Repo --include $Include --local-dir $tmp
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        throw "Download failed for $Repo (pattern $Include)"
    }

    $file = Get-ChildItem $tmp -Recurse -File |
        Where-Object { $_.Name -like $DestFile } | Select-Object -First 1
    if (-not $file) {
        $file = Get-ChildItem $tmp -Recurse -File -Filter "*.gguf" | Select-Object -First 1
    }
    if (-not $file) {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        throw "No matching file found in download for $Label"
    }

    Move-Item $file.FullName $destPath -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    $gb = [math]::Round((Get-Item $destPath).Length / 1GB, 2)
    Write-Ok "$Label -> models\$DestFile ($gb GB)"
}

# =============================================================================
# MAIN
# =============================================================================
Write-Banner "LLM Server - Setup & Update" "llama.cpp + Docker, OpenAI-compatible on :$ServerPort"

foreach ($d in @($ModelsDir, $LogsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
if (-not (Test-Path $EnvFile)) {
    $example = Join-Path $ScriptDir ".env.example"
    if (Test-Path $example) { Copy-Item $example $EnvFile }
}

# --- 1. Docker Desktop -------------------------------------------------------
Write-Step "Docker Desktop"
Add-DockerToPath
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Info "Docker not found, installing via winget..."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Err "winget missing. Install Docker Desktop from https://docker.com and re-run."
        exit 1
    }
    winget install --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
    Write-Warn "Docker Desktop installed. Restart Windows, launch Docker once, then re-run .\setup.ps1"
    exit 0
}
if (-not (Start-DockerDesktop)) {
    Write-Err "Docker Desktop did not become ready. Start it manually and re-run."
    exit 1
}
Write-Ok "Docker is running"

# --- 2. GPU access -----------------------------------------------------------
Write-Step "GPU access in Docker"
$prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    $gpu = docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi 2>&1 | Out-String
    $gpuExit = $LASTEXITCODE
} finally { $ErrorActionPreference = $prevEap }
if ($gpuExit -ne 0) {
    Write-Err "GPU not accessible inside Docker. Check:"
    Write-Info "nvidia-smi works on the host"
    Write-Info "Docker Desktop > Settings > Resources > WSL Integration is enabled"
    Write-Host $gpu -ForegroundColor DarkGray
    exit 1
}
$gpuName = ($gpu -split "`n" | Select-String "NVIDIA" | Select-Object -First 1)
Write-Ok ("GPU visible: " + $(if ($gpuName) { $gpuName.ToString().Trim() } else { "nvidia-smi ok" }))

# --- 3. Hugging Face CLI -----------------------------------------------------
Write-Step "Hugging Face CLI"
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Err "Python not found. Install Python 3, then re-run."
    exit 1
}
Write-Info "Ensuring latest 'hf' CLI (huggingface_hub + hf_transfer)..."
python -m pip install --quiet --upgrade huggingface_hub hf_transfer
$hf = Get-HfCommand
if (-not $hf) { Write-Err "'hf' CLI still not on PATH after install."; exit 1 }
$hfVersion = (& $hf.Name version 2>&1 | Out-String).Trim()
Write-Ok "hf ready ($hfVersion)"

$token = Get-DotEnvValue "HF_TOKEN"
if ($token -and $token -ne "hf_xxx") {
    $env:HF_TOKEN = $token
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        & $hf.Name auth login --token $token --add-to-git-credential 2>&1 | Out-Null
        Write-Ok "Authenticated with Hugging Face (token from .env)"
    } catch {
        Write-Warn "HF auth login had warnings, but token is set"
    } finally {
        $ErrorActionPreference = $prevEap
    }
} else {
    Write-Warn "No HF_TOKEN in .env - public models still work; gated ones will fail."
}

# --- 4. API key --------------------------------------------------------------
Write-Step "Server API key"
$apiKey = Get-DotEnvValue "LLAMA_API_KEY"
if (-not $apiKey -or $apiKey -eq "sk-xxx") {
    $apiKey = New-ApiKey
    Set-DotEnvValue "LLAMA_API_KEY" $apiKey
    Write-Ok "Generated a new API key and saved it to .env"
} else {
    Write-Skip "API key already present in .env"
}
Write-Info "Clients authenticate with: Authorization: Bearer $apiKey"
Write-Info "Put this key in your client config (e.g. opencode/opencode.json)"

# --- 5. llama.cpp image ------------------------------------------------------
Write-Step "llama.cpp server image"
Invoke-Compose @("pull", "llm")
Write-Ok "Image up to date (tag from docker-compose.yml)"

# --- 6. usage-tracker proxy --------------------------------------------------
Write-Step "usage-tracker proxy"
Invoke-Compose @("build", "--pull", "usage-tracker")
Write-Ok "Proxy image built"

# --- 7. Model ----------------------------------------------------------------
Write-Step "Model download"
if ($SkipModel) {
    Write-Skip "Skipped (-SkipModel)"
} else {
    $m = $Models[$Model]
    Write-Info "Target: $($m.Label)"
    Get-ModelFromHub -Repo $m.Repo       -Include $m.Include       -DestFile $m.File       -Label $m.Label
    Get-ModelFromHub -Repo $m.MmprojRepo -Include $m.MmprojInclude -DestFile $m.MmprojFile -Label "vision projector"
}

# --- 8. Firewall -------------------------------------------------------------
Write-Step "Windows Firewall"
$ruleName = "LLM Server Port $ServerPort"
if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
    Write-Skip "Rule '$ruleName' already exists"
} else {
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try {
        $result = New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
            -LocalPort $ServerPort -Action Allow -Profile Any -Enabled True 2>&1
        if ($result -and -not ($result -match "Access is denied")) {
            Write-Ok "Opened inbound TCP $ServerPort"
        } else {
            Write-Warn "Could not add rule (run as Administrator for LAN access)"
        }
    } catch {
        Write-Warn "Could not add rule (run as Administrator for LAN access)"
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# --- 9. Cleanup --------------------------------------------------------------
Write-Step "Docker cleanup"
$prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    if ($Clean) {
        Write-Info "Removing ALL unused images (-Clean)..."
        docker image prune -a -f | Out-Null
    } else {
        Write-Info "Removing dangling layers..."
        docker image prune -f | Out-Null
    }
} finally { $ErrorActionPreference = $prevEap }
Write-Ok "Cleanup done"

# --- Summary -----------------------------------------------------------------
Write-Banner "Setup complete" "Start the server below"
Write-Host ""
Write-Host "  .\run.ps1                     # start default ($($Models[$Model].Label))" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model qwen35-9b    # lighter model" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Stop               # stop the server" -ForegroundColor Gray
Write-Host ""
Write-Host "  API:      http://localhost:$ServerPort/v1" -ForegroundColor White
Write-Host "  API key:  $apiKey" -ForegroundColor White
Write-Host "            (send as 'Authorization: Bearer <key>')" -ForegroundColor DarkGray
Write-Host ""
