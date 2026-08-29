<#
.SYNOPSIS
    One-stop setup + update for the Docker-based llama.cpp LLM server.

.DESCRIPTION
    Idempotent. Safe to run any number of times - the first run installs
    everything, later runs update it. Each step is skipped if already done.

      0. Pre-flight           verify Docker, Python, uv, Git are available
      1. Docker Desktop        install (winget) + start
      2. GPU access            verify NVIDIA runtime inside Docker
      3. Hugging Face CLI      install/upgrade latest 'hf' + login from .env
      4. Server API key        generate a random key into .env (if missing)
      5. llama.cpp image       pull the latest image tag from docker-compose.yml
      6. gateway proxy        (re)build from this repo's Dockerfile
      7. MCP dependencies     pre-install MCP Python packages via uv
      8. Model                 download GGUF + vision projector into .\models\
      9. Firewall              open the server port for LAN access
     10. Cleanup               prune dangling Docker layers (models untouched)

.PARAMETER Model
    Which model to ensure is downloaded: "qwen36" (default), "heretic", "qwen35-9b", or "qwen35-4b".

.PARAMETER SkipModel
    Skip the model download step (just refresh Docker + tooling).

.PARAMETER Clean
    Aggressive cleanup: remove ALL unused images, not just dangling layers.

.EXAMPLE
    .\setup.ps1                     # full setup / update with the default model
    .\setup.ps1 -Model heretic      # also fetch the Heretic Cerebellum 14GB model
    .\setup.ps1 -Model qwen35-9b    # also fetch the lighter 9B model
    .\setup.ps1 -Model qwen35-4b    # also fetch the tiny 4B model
    .\setup.ps1 -SkipModel          # update Docker + tooling only
    .\setup.ps1 -Clean              # update and reclaim disk aggressively
#>

[CmdletBinding()]
param(
    [string]$Model = "",

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
# ELEVATION — re-launch elevated if needed (Docker install, firewall, hardlinks)
# =============================================================================
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DeveloperMode {
    try {
        $dm = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction Stop
        return ($dm.AllowDevelopmentWithoutDevLicense -eq 1)
    } catch {
        return $false
    }
}

$isAdmin = Test-Admin
$devMode = Test-DeveloperMode

# If not elevated and Docker is missing (needs winget install), re-launch elevated
if (-not $isAdmin) {
    $dockerFound = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerFound) {
        $dockerBin = @("D:\Docker\resources\bin", "C:\Program Files\Docker\Docker\resources\bin") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $dockerBin) {
            Write-Host ""
            Write-Host "  Docker Desktop is not installed and requires Administrator to install." -ForegroundColor Yellow
            Write-Host "  Re-launching setup as Administrator..." -ForegroundColor Cyan
            Write-Host ""
            $elevatedArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            foreach ($key in $PSBoundParameters.Keys) {
                $val = $PSBoundParameters[$key]
                if ($val -is [switch] -and $val) { $elevatedArgs += " -$key" }
                elseif ($val) { $elevatedArgs += " -$key `"$val`"" }
            }
            Start-Process powershell -Verb RunAs -ArgumentList $elevatedArgs
            exit
        }
    }
}

    if (-not $devMode -and -not $isAdmin) {
        Write-Host ""
        Write-Host "  [info] Developer Mode is OFF and not running as Administrator." -ForegroundColor Yellow
        Write-Host "         Hardlinks will fall back to file copies (works, just uses more disk)." -ForegroundColor Yellow
        Write-Host ('         To enable hardlinks: Settings > System > For developers > Developer Mode') -ForegroundColor DarkGray
        Write-Host ""
    }

# =============================================================================
# MODEL CATALOG - loaded from models.yaml (single source of truth)
# =============================================================================
function Load-ModelCatalog {
    $configPath = Join-Path $ScriptDir "model_config.py"
    $json = & uv run --with pyyaml python $configPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to load models.yaml: $json" }
    return $json | ConvertFrom-Json
}

$Config = Load-ModelCatalog

function Resolve-ModelId {
    param([string]$Name)
    if ($Config.models.PSObject.Properties[$Name]) { return $Name }
    foreach ($prop in $Config.models.PSObject.Properties) {
        if ($prop.Value.aliases -contains $Name) { return $prop.Name }
    }
    return $null
}

# =============================================================================
# TUI
# =============================================================================
$script:Step = 0
$script:StepTotal = 11
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
    # Prefer 'hf' (standalone CLI), fall back to 'huggingface-cli' (from huggingface_hub)
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

function Ensure-UsageDataStorage {
    $dataDir = Join-Path $ScriptDir "usage_data"
    $dataFile = Join-Path $dataDir "usage_data.json"
    $legacyPath = Join-Path $ScriptDir "usage_data.json"

    if (Test-Path $legacyPath -PathType Leaf) {
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        Move-Item -Force $legacyPath $dataFile
    } elseif (Test-Path $legacyPath -PathType Container) {
        Remove-Item -Recurse -Force $legacyPath
    }

    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    if (-not (Test-Path $dataFile) -and -not (Test-Path (Join-Path $dataDir "requests.jsonl"))) {
        if (Test-Path $legacyPath -PathType Leaf) {
            Move-Item -Force $legacyPath $dataFile
        }
    }
}

function Get-HfCacheDir {
    # Resolve the HF cache directory: respect HF_HOME, then default
    if ($env:HF_HOME) {
        $hubCache = Join-Path $env:HF_HOME "hub"
        if (Test-Path $hubCache) { return $hubCache }
    }
    $default = Join-Path $env:USERPROFILE ".cache\huggingface\hub"
    if (Test-Path $default) { return $default }
    # If neither exists, return the default (create on first download)
    return $default
}

function Find-HfCacheFile {
    param([string]$Repo, [string]$Include)
    $hubCache = Get-HfCacheDir
    if (-not (Test-Path $hubCache)) { return $null }

    $repoDir = "models--" + ($Repo -replace "/", "--")
    $repoPath = Join-Path $hubCache $repoDir
    if (-not (Test-Path $repoPath)) { return $null }

    $snapshots = Join-Path $repoPath "snapshots"
    if (-not (Test-Path $snapshots)) { return $null }

    $latest = Get-ChildItem $snapshots -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return $null }

    return Get-ChildItem $latest.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $Include } | Select-Object -First 1
}

function New-HardlinkOrCopy {
    param([string]$LinkPath, [string]$TargetPath)
    if (Test-Path $LinkPath) {
        $item = Get-Item $LinkPath -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item $LinkPath -Force -ErrorAction SilentlyContinue
        } else {
            cmd /c "del /f /q `"$LinkPath`"" 2>$null
        }
    }
    $resolved = $TargetPath
    $srcItem = Get-Item $TargetPath -Force -ErrorAction SilentlyContinue
    if ($srcItem -and ($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $chain = cmd /c "dir `"$TargetPath`"" 2>$null | Select-String '\[([^\]]+)\]$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        if ($chain) {
            $resolved = $chain
            if (-not [System.IO.Path]::IsPathRooted($chain)) {
                $resolved = Join-Path (Split-Path $TargetPath -Parent) $chain
            }
        }
    }
    $null = fsutil hardlink create `"$LinkPath`" `"$resolved`" 2>&1
    if (Test-Path $LinkPath) { return $true }
    Copy-Item -LiteralPath $resolved -Destination $LinkPath -Force
    return (Test-Path $LinkPath)
}

function Get-ModelFromHub {
    param([string]$Repo, [string]$Include, [string]$DestFile, [string]$Label)

    $destPath = Join-Path $ModelsDir $DestFile

    # Check if a valid file already exists and is readable
    if (Test-Path $destPath) {
        $item = Get-Item $destPath -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            # Convert symlinks to hardlinks (Docker WSL2 can't follow symlinks)
            $resolved = $destPath
            for ($i = 0; $i -lt 10; $i++) {
                $raw = cmd /c "dir `"$resolved`"" 2>$null | Select-String '\[([^\]]+)\]$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
                if (-not $raw) { break }
                $next = $raw
                if (-not [System.IO.Path]::IsPathRooted($raw)) {
                    $next = Join-Path (Split-Path $resolved -Parent) $raw
                }
                $resolved = $next
                $nextItem = Get-Item $resolved -Force -ErrorAction SilentlyContinue
                if (-not $nextItem -or -not ($nextItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { break }
            }
            if ($resolved -ne $destPath -and (Test-Path $resolved)) {
                Remove-Item $destPath -Force -ErrorAction SilentlyContinue
                $null = fsutil hardlink create `"$destPath`" `"$resolved`" 2>&1
                if (-not (Test-Path $destPath)) {
                    Copy-Item -LiteralPath $resolved -Destination $destPath -Force
                }
            }
        }
        try {
            $item = Get-Item $destPath -Force
            $null = [System.IO.File]::OpenRead($item.FullName).Dispose()
            $gb = [math]::Round($item.Length / 1GB, 2)
            Write-Skip "$Label already present ($gb GB)"
            return
        } catch {
            Write-Warn "Existing $Label unreadable, re-downloading..."
        }
    }

    # Check HF cache first (avoids re-downloading if already cached)
    $cached = Find-HfCacheFile -Repo $Repo -Include $Include
    if ($cached) {
        Write-Info "Found $Label in HF cache, linking..."
        $ok = New-HardlinkOrCopy -LinkPath $destPath -TargetPath $cached.FullName
        if ($ok) {
            $gb = [math]::Round((Get-Item $destPath -Force).Length / 1GB, 2)
            $method = if ((Get-Item $destPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { "symlinked" } else { "hardlinked" }
            Write-Ok "$Label ($gb GB, $method from HF cache)"
            return
        }
        Write-Warn "Link failed, downloading fresh..."
    }

    # Download to default HF cache
    Write-Info "Downloading $Label from $Repo ..."
    $hf = Get-HfCommand
    if (-not $hf) {
        throw "'hf' CLI not found. Ensure 'uv' is installed and run: uv tool install --force hf"
    }

    $env:PYTHONIOENCODING = "utf-8"
    $env:PYTHONUTF8 = "1"
    Remove-Item Env:TQDM_POSITION -ErrorAction SilentlyContinue
    Remove-Item Env:HF_HUB_ENABLE_HF_TRANSFER -ErrorAction SilentlyContinue
    Remove-Item Env:HF_HUB_DISABLE_PROGRESS_BARS -ErrorAction SilentlyContinue

    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        & $hf.Source download $Repo --include $Include
        $dlExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }

    if ($dlExit -ne 0) {
        throw "Download failed for $Repo (exit $dlExit, pattern: $Include)"
    }

    # Find the downloaded file in the HF cache
    $cached = Find-HfCacheFile -Repo $Repo -Include $Include
    if (-not $cached) {
        throw "Download succeeded but no matching file found in HF cache for $Label (pattern: $Include)"
    }

    $ok = New-HardlinkOrCopy -LinkPath $destPath -TargetPath $cached.FullName
    $gb = [math]::Round((Get-Item $destPath -Force).Length / 1GB, 2)
    $method = if ((Get-Item $destPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { "symlinked" } else { "hardlinked" }
    Write-Ok "$Label ($gb GB, $method from HF cache)"
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

# --- 0. Pre-flight checks ----------------------------------------------------
Write-Step "Pre-flight checks"
$missing = @()
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    # Check common Docker Desktop install paths before giving up
    $dockerBin = @("D:\Docker\resources\bin", "C:\Program Files\Docker\Docker\resources\bin") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $dockerBin) { $missing += "Docker Desktop" }
}
if (-not (Get-Command python -ErrorAction SilentlyContinue) -and -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
    $missing += "Python 3 (install from https://python.org or winget install Python.Python.3.12)"
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    $missing += "uv (install: powershell -ExecutionPolicy ByPass -c 'irm https://astral.sh/uv/install.ps1 | iex')"
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $missing += "Git (install: winget install Git.Git)"
}
if ($missing.Count -gt 0) {
    Write-Err "Missing prerequisites:"
    $missing | ForEach-Object { Write-Host "        - $_" -ForegroundColor Yellow }
    exit 1
}
Write-Ok "Docker, Python, uv, Git all found"

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
    Write-Info ('Docker Desktop > Settings > Resources > WSL Integration is enabled')
    Write-Host $gpu -ForegroundColor DarkGray
    exit 1
}
$gpuName = ($gpu -split "`n" | Select-String "NVIDIA" | Select-Object -First 1)
Write-Ok ("GPU visible: " + $(if ($gpuName) { $gpuName.ToString().Trim() } else { "nvidia-smi ok" }))

# --- 3. Hugging Face CLI -----------------------------------------------------
Write-Step "Hugging Face CLI"
Write-Info "Ensuring 'hf' CLI is installed via uv..."
$prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    uv tool install --force hf 2>&1 | Out-Null
} finally {
    $ErrorActionPreference = $prevEap
}
$hf = Get-HfCommand
if (-not $hf) {
    Write-Err "'hf' CLI not found after install. Try: uv tool install --force hf"
    exit 1
}
$prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    $hfVersion = (& $hf.Source version 2>&1 | Out-String).Trim()
} finally {
    $ErrorActionPreference = $prevEap
}
Write-Ok "hf ready ($hfVersion)"

$token = Get-DotEnvValue "HF_TOKEN"
if ($token -and $token -ne "hf_xxx") {
    $env:HF_TOKEN = $token
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        & $hf.Source auth login --token $token --add-to-git-credential 2>&1 | Out-Null
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

# --- 6. gateway proxy ---------------------------------------------------------
Write-Step "gateway proxy"
Ensure-UsageDataStorage
Invoke-Compose @("build", "--pull", "gateway")
Write-Ok "Gateway image built"

# --- 7. MCP server dependencies -----------------------------------------------
Write-Step "MCP server dependencies"
$reqFile = Join-Path $ScriptDir "mcp\requirements.txt"
if (-not (Test-Path $reqFile)) {
    Write-Skip "mcp/requirements.txt not found"
} else {
    Write-Info "Pre-installing MCP Python packages via uv..."
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        $out = & uv run --with-requirements $reqFile python -c "import mcp, httpx, uvicorn, yaml; print('ok')" 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($exitCode -eq 0) {
        Write-Ok "MCP dependencies cached (mcp, httpx, uvicorn, pyyaml)"
    } else {
        Write-Warn "Could not pre-install MCP deps (exit $exitCode). run.ps1 will retry on start."
        if ($out) { $out -split "`n" | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray } }
    }
}

# --- 8. Model ----------------------------------------------------------------
Write-Step "Model download"
if ($SkipModel) {
    Write-Skip "Skipped (-SkipModel)"
} else {
    if (-not $Model) { $Model = $Config.default_model }
    $resolved = Resolve-ModelId $Model
    if (-not $resolved) {
        $validIds = @($Config.models.PSObject.Properties.Name)
        Write-Err "Unknown model '$Model'. Valid: $($validIds -join ', ')"
        exit 1
    }
    $Model = $resolved
    $m = $Config.models.$Model
    Write-Info "Target: $($m.label)"
    Get-ModelFromHub -Repo $m.repo -Include $m.include -DestFile $m.file -Label $m.label
    if ($m.mmproj_repo -and $m.mmproj_include -and $m.mmproj_file) {
        Get-ModelFromHub -Repo $m.mmproj_repo -Include $m.mmproj_include -DestFile $m.mmproj_file -Label "vision projector"
    } else {
        Write-Info "No vision projector defined for this model, skipping"
    }
}

# --- 9. Firewall -------------------------------------------------------------
Write-Step "Windows Firewall"
if (-not $isAdmin) {
    Write-Skip "Not running as Administrator -- skipping firewall rule"
    Write-Info "To allow LAN access, run once as Administrator or add manually:"
    Write-Info "  netsh advfirewall firewall add rule name=""LLM Server Port $ServerPort"" dir=in action=allow protocol=TCP localport=$ServerPort"
} else {
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
                Write-Warn "Could not add rule"
            }
        } catch {
            Write-Warn "Could not add rule"
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }
}

# --- 10. Cleanup -------------------------------------------------------------
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
    if (-not $isAdmin -and -not $devMode) {
        Write-Host "  [note] Models were copied (not hardlinked). Enable Developer Mode for hardlinks:" -ForegroundColor Yellow
        Write-Host ('         Settings > System > For developers > Developer Mode') -ForegroundColor DarkGray
        Write-Host ""
    }
$defaultLabel = $Config.models.($Config.default_model).label
Write-Host "  .\run.ps1                     # start default ($defaultLabel)" -ForegroundColor Gray
foreach ($prop in $Config.models.PSObject.Properties) {
    $id = $prop.Name; $aliases = ($prop.Value.aliases -join "/")
    Write-Host "  .\run.ps1 -Model $($id.PadRight(14)) # $aliases - $($prop.Value.label)" -ForegroundColor Gray
}
Write-Host "  .\run.ps1 -Stop               # stop the server" -ForegroundColor Gray
Write-Host ""
Write-Host "  API:      http://localhost:$ServerPort/v1" -ForegroundColor White
Write-Host "  API key:  $apiKey" -ForegroundColor White
Write-Host "            (send as 'Authorization: Bearer <key>')" -ForegroundColor DarkGray
Write-Host ""
