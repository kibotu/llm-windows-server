<#
.SYNOPSIS
    Start, reconcile, or stop the llama.cpp LLM server (Docker).

.DESCRIPTION
    Idempotent. Run it as often as you like - each run reconciles the live
    container to the requested settings (compose recreates it only when the
    config actually changes). Missing models are auto-downloaded from Hugging
    Face. The script stays in the foreground streaming logs; Ctrl+C stops
    streaming but leaves the server running. Use -Stop to tear it down.

    Defaults target an RTX 4080 16 GB + 96 GB DDR5 box running Qwen3.6-35B-A3B
    at IQ4_XS with vision, reasoning, and MoE experts offloaded to RAM.

.PARAMETER Model
    "qwen36" (default, 35B MoE + vision) or "qwen35-9b" (lighter dense + vision).

.PARAMETER Context
    Total KV context tokens (default: 262144).

.PARAMETER Parallel
    Concurrent request slots (default: 1). Context is split across slots.

.PARAMETER Thinking
    Extended reasoning / <think> blocks (default: $true).

.PARAMETER Vision
    Enable the vision projector (default: auto - on when the mmproj file exists).

.PARAMETER Threads
    CPU threads (default: 0 = auto from logical CPU count).

.PARAMETER Batch
    Physical batch size -b (default: 2048; auto-raised to 4096 for MoE).

.PARAMETER UBatch
    Micro-batch size -ub (default: 2048; kept equal to -b for MoE).

.PARAMETER KvCache
    KV cache quantization: q8_0 (default), q4_0 (save VRAM), f16 (best quality).

.PARAMETER MoeOffload
    Expert offload: "auto"/"all" (experts to CPU), "off" (full GPU), or N (first N layers).

.PARAMETER ExtraFlags
    Extra flags appended verbatim to llama-server.

.PARAMETER NoDownload
    Fail instead of auto-downloading a missing model.

.PARAMETER Stop
    Stop the server and exit.

.EXAMPLE
    .\run.ps1                            # Qwen3.6 35B, vision + reasoning, 262k ctx
    .\run.ps1 -Model qwen35-9b           # lighter 9B model
    .\run.ps1 -Context 65536 -Parallel 4 # 4 slots, shorter context (reconciles live)
    .\run.ps1 -KvCache q4_0              # save VRAM
    .\run.ps1 -Stop                      # stop the server
#>

[CmdletBinding()]
param(
    [ValidateSet("qwen36", "qwen35-9b")]
    [string]$Model = "qwen36",

    [int]$Context = 262144,

    [int]$Parallel = 1,

    [bool]$Thinking = $true,

    [object]$Vision = $null,

    [ValidateRange(0, 256)]
    [int]$Threads = 0,

    [int]$Batch = 2048,

    [int]$UBatch = 2048,

    [ValidateSet("q4_0", "q8_0", "f16")]
    [string]$KvCache = "q8_0",

    [ValidatePattern("^(auto|off|all|\d+)$")]
    [string]$MoeOffload = "auto",

    [string]$ExtraFlags = "",

    [switch]$NoDownload,

    [switch]$Stop
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ComposeFile = Join-Path $ScriptDir "docker-compose.yml"
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch { }

# =============================================================================
# MODEL CATALOG (must match setup.ps1)
# =============================================================================
$Models = @{
    "qwen36" = @{
        Repo          = "unsloth/Qwen3.6-35B-A3B-GGUF"
        File          = "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"
        Include       = "*UD-IQ4_XS*"
        MmprojRepo    = "unsloth/Qwen3.6-35B-A3B-GGUF"
        MmprojFile    = "Qwen3.6-35B-A3B-mmproj-BF16.gguf"
        MmprojInclude = "*mmproj-BF16*"
        IsMoe         = $true
        Label         = "Qwen3.6-35B-A3B IQ4_XS (vision, MoE)"
    }
    "qwen35-9b" = @{
        Repo          = "unsloth/Qwen3.5-9B-GGUF"
        File          = "Qwen3.5-9B-Q4_K_M.gguf"
        Include       = "*Q4_K_M*"
        MmprojRepo    = "unsloth/Qwen3.5-9B-GGUF"
        MmprojFile    = "Qwen3.5-9B-mmproj-BF16.gguf"
        MmprojInclude = "*mmproj-BF16*"
        IsMoe         = $false
        Label         = "Qwen3.5-9B Q4_K_M (vision, dense)"
    }
}

# =============================================================================
# TUI
# =============================================================================
$script:Step = 0
$script:StepTotal = 5

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
    $envFile = Join-Path $ScriptDir ".env"
    if (-not (Test-Path $envFile)) { return $null }
    $line = Get-Content $envFile | Where-Object { $_ -match "^\s*$Key\s*=\s*(.+)$" } | Select-Object -First 1
    if ($line -and $line -match "^\s*$Key\s*=\s*(.+)$") { return $Matches[1].Trim() }
    return $null
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

function Get-LocalIp {
    $adapters = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" })
    if ($adapters.Count -eq 0) { return "127.0.0.1" }
    $eth = @($adapters | Where-Object { $_.InterfaceAlias -like "Ethernet*" })
    if ($eth.Count -gt 0) { return $eth[0].IPAddress }
    $wifi = @($adapters | Where-Object { $_.InterfaceAlias -like "Wi-Fi*" })
    if ($wifi.Count -gt 0) { return $wifi[0].IPAddress }
    return $adapters[0].IPAddress
}

function Get-ModelFromHub {
    param([string]$Repo, [string]$Include, [string]$DestFile, [string]$Label)
    Write-Info "Downloading $Label from $Repo ..."
    $hf = Get-Command hf -ErrorAction SilentlyContinue
    if (-not $hf) { $hf = Get-Command huggingface-cli -ErrorAction SilentlyContinue }
    if (-not $hf) { throw "'hf' CLI not found. Run .\setup.ps1 first." }

    $token = Get-DotEnvValue "HF_TOKEN"
    if ($token -and $token -ne "hf_xxx" -and -not $env:HF_TOKEN) { $env:HF_TOKEN = $token }
    $env:HF_HUB_ENABLE_HF_TRANSFER = "1"

    $tmp = Join-Path $env:TEMP ("hf_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    & $hf.Name download $Repo --include $Include --local-dir $tmp
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        throw "Download failed for $Repo (pattern $Include)"
    }
    $file = Get-ChildItem $tmp -Recurse -File | Where-Object { $_.Name -like $DestFile } | Select-Object -First 1
    if (-not $file) { $file = Get-ChildItem $tmp -Recurse -File -Filter "*.gguf" | Select-Object -First 1 }
    if (-not $file) {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        throw "No matching file in download for $Label"
    }
    Move-Item $file.FullName (Join-Path $ScriptDir "models\$DestFile") -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "$Label ready"
}

# =============================================================================
# MAIN
# =============================================================================
Write-Banner "LLM Server" "llama.cpp + Docker on :8899"

Add-DockerToPath

# --- Stop shortcut -----------------------------------------------------------
if ($Stop) {
    Write-Step "Stopping server"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Write-Err "Docker not found."; exit 1 }
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { docker compose -f $ComposeFile down 2>&1 | Out-Null } finally { $ErrorActionPreference = $prevEap }
    Write-Ok "Server stopped"
    exit 0
}

# --- 1. Docker ---------------------------------------------------------------
Write-Step "Docker"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Write-Err "Docker not found. Run .\setup.ps1 first."; exit 1 }
if (-not (Start-DockerDesktop)) { Write-Err "Docker Desktop did not become ready."; exit 1 }
Write-Ok "Docker is running"

# --- 2. Model ----------------------------------------------------------------
Write-Step "Model"
$reg = $Models[$Model]
$modelsDir = Join-Path $ScriptDir "models"
if (-not (Test-Path $modelsDir)) { New-Item -ItemType Directory -Path $modelsDir | Out-Null }

$modelPath  = Join-Path $modelsDir $reg.File
$mmprojPath = Join-Path $modelsDir $reg.MmprojFile

if (-not (Test-Path $modelPath)) {
    if ($NoDownload) { Write-Err "Model missing: $($reg.File) (remove -NoDownload to fetch it)"; exit 1 }
    Get-ModelFromHub -Repo $reg.Repo -Include $reg.Include -DestFile $reg.File -Label $reg.Label
}

$enableVision = if ($null -ne $Vision) { [bool]$Vision } else { $true }
if ($enableVision -and -not (Test-Path $mmprojPath) -and -not $NoDownload) {
    Get-ModelFromHub -Repo $reg.MmprojRepo -Include $reg.MmprojInclude -DestFile $reg.MmprojFile -Label "vision projector"
}
if ($enableVision -and -not (Test-Path $mmprojPath)) {
    Write-Warn "Vision projector not available - running without vision"
    $enableVision = $false
}
$modelGb = [math]::Round((Get-Item $modelPath).Length / 1GB, 2)
Write-Ok "$($reg.Label) ($modelGb GB)"

# --- 3. Configure ------------------------------------------------------------
Write-Step "Configuration"

$logicalCpus = [Environment]::ProcessorCount
$threadsAuto = $Threads -le 0
if ($threadsAuto) {
    if     ($logicalCpus -ge 32) { $Threads = 20 }
    elseif ($logicalCpus -ge 16) { $Threads = 12 }
    else                         { $Threads = [math]::Max(4, [int][math]::Ceiling($logicalCpus / 2.0)) }
}

$moeFlags = ""
if ($reg.IsMoe) {
    switch ($MoeOffload) {
        "auto" { $moeFlags = "--cpu-moe" }
        "all"  { $moeFlags = "--cpu-moe" }
        "off"  { $moeFlags = "" }
        default { if ($MoeOffload -match '^\d+$') { $moeFlags = "--n-cpu-moe $MoeOffload" } }
    }
    if ($Batch -eq 2048 -and $UBatch -eq 2048 -and $MoeOffload -ne "off") { $Batch = 4096; $UBatch = 4096 }
}

$mmprojFlags = if ($enableVision) { "--mmproj /models/$($reg.MmprojFile)" } else { "" }

Write-Info ("Vision:    " + $(if ($enableVision) { "on" } else { "off" }))
Write-Info ("Context:   $Context tokens" + $(if ($Parallel -gt 1) { " ($([int]($Context / $Parallel))/slot x $Parallel)" } else { "" }))
Write-Info ("Reasoning: " + $(if ($Thinking) { "on" } else { "off" }))
Write-Info ("Threads:   $Threads " + $(if ($threadsAuto) { "(auto from $logicalCpus CPUs)" } else { "(manual)" }))
Write-Info ("Batch/UB:  $Batch / $UBatch")
Write-Info ("KV cache:  $KvCache")
Write-Info ("MoE:       " + $(if ($reg.IsMoe) { if ($moeFlags) { "$MoeOffload (experts->CPU)" } else { "off (full GPU)" } } else { "n/a (dense)" }))

$env:MODEL_FILE        = $reg.File
$env:MMPROJ_FLAGS      = $mmprojFlags
$env:CONTEXT_SIZE      = $Context.ToString()
$env:KV_CACHE_TYPE     = $KvCache
$env:THREADS           = $Threads.ToString()
$env:BATCH_SIZE        = $Batch.ToString()
$env:UBATCH_SIZE       = $UBatch.ToString()
$env:N_PARALLEL        = $Parallel.ToString()
$env:REASONING         = if ($Thinking) { "on" } else { "off" }
$env:MOE_FLAGS         = $moeFlags
$env:EXTRA_LLAMA_FLAGS = $ExtraFlags
Write-Ok "Environment set"

# --- 4. Start / reconcile ----------------------------------------------------
Write-Step "Starting server"
$prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    $out = docker compose -f $ComposeFile up -d 2>&1
    $exit = $LASTEXITCODE
} finally { $ErrorActionPreference = $prevEap }
$out | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
if ($exit -ne 0) { Write-Err "docker compose up failed (exit $exit)"; exit 1 }
Write-Ok "Container reconciled"

# --- 5. Wait for health ------------------------------------------------------
Write-Step "Waiting for health"
$timeout = 300
$start = Get-Date
while ($true) {
    $health = docker inspect --format '{{.State.Health.Status}}' llm-server 2>$null
    if ($health -eq "healthy") { Write-Host ""; Write-Ok "Server is ready"; break }
    if (((Get-Date) - $start).TotalSeconds -gt $timeout) {
        Write-Host ""
        Write-Err "Not healthy within ${timeout}s. Check: docker compose logs llm"
        exit 1
    }
    Start-Sleep -Seconds 3
    Write-Host "." -NoNewline -ForegroundColor DarkGray
}

# --- Banner ------------------------------------------------------------------
$localIp = Get-LocalIp
Write-Banner "SERVER RUNNING" "$($reg.Label)"
Write-Host ""
Write-Host "  Local:  http://localhost:8899/v1" -ForegroundColor White
Write-Host "  LAN:    http://${localIp}:8899/v1" -ForegroundColor White
Write-Host ""
Write-Host "  Reasoning: $(if ($Thinking) { 'on' } else { 'off' })    Vision: $(if ($enableVision) { 'on' } else { 'off' })    Context: $Context" -ForegroundColor Gray
Write-Host "  API key:   any string (not validated)" -ForegroundColor Gray
Write-Host ""
Write-Host "  .\run.ps1 -Stop   stop     |   docker compose logs -f   logs" -ForegroundColor DarkGray

# --- Stream logs (foreground) ------------------------------------------------
Write-Host ""
Write-Host "  [logs] Ctrl+C stops streaming; the server keeps running." -ForegroundColor DarkGray
Write-Host ""
docker compose -f $ComposeFile logs -f
