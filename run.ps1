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
    Model id or alias from models.yaml. Use aliases like "big", "small", "tiny",
    or canonical ids like "qwen36", "qwen35-4b". Default: from models.yaml.

.PARAMETER Context
    Total KV context tokens. Defaults to the model's default from models.yaml.

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

.PARAMETER NoFollow
    Reconcile the container and wait for health, then exit without streaming logs.
    Used by host_controller.py for remote model switches.

.EXAMPLE
    .\run.ps1                            # Qwen3.6 35B, vision + reasoning, 262k ctx
    .\run.ps1 -Model heretic             # Heretic Cerebellum 14GB MoE + vision
    .\run.ps1 -Model qwen35-9b           # lighter 9B model
    .\run.ps1 -Model qwen35-4b           # tiny 4B model
    .\run.ps1 -Context 65536 -Parallel 4 # 4 slots, shorter context (reconciles live)
    .\run.ps1 -KvCache q4_0              # save VRAM
    .\run.ps1 -Stop                      # stop the server
    .\run.ps1 -Model qwen35-9b -NoFollow # reconcile only (for host_controller / admin API)
#>

[CmdletBinding()]
param(
    [string]$Model = "",

    [int]$Context = 0,

    [int]$Parallel = 1,

    [bool]$Thinking = $true,

    [object]$Vision = $null,

    [ValidateRange(0, 256)]
    [int]$Threads = 0,

    [int]$Batch = 2048,

    [int]$UBatch = 2048,

    [ValidateSet("q4_0", "q8_0", "f16", "")]
    [string]$KvCache = "",

    [ValidatePattern("^(auto|off|all|\d+)$")]
    [string]$MoeOffload = "auto",

    [string]$ExtraFlags = "",

    [switch]$NoDownload,

    [switch]$Stop,

    [switch]$NoFollow
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ComposeFile = Join-Path $ScriptDir "docker-compose.yml"
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch { }
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

# =============================================================================
# MODEL CATALOG — loaded from models.yaml (single source of truth)
# =============================================================================
function Load-ModelCatalog {
    $configPath = Join-Path $ScriptDir "model_config.py"
    $json = & uv run python $configPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to load models.yaml: $json" }
    return $json | ConvertFrom-Json
}

$Config = Load-ModelCatalog
$ValidModelIds = @($Config.models.PSObject.Properties.Name)
$Config.models.PSObject.Properties | ForEach-Object {
    $_.Value.aliases | ForEach-Object { $ValidModelIds += $_ }
}

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
    # Legacy single-file store is migrated by gateway on startup.
    if (-not (Test-Path $dataFile) -and -not (Test-Path (Join-Path $dataDir "requests.jsonl"))) {
        if (Test-Path $legacyPath -PathType Leaf) {
            Move-Item -Force $legacyPath $dataFile
        }
    }
}
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

function Write-RuntimeState {
    param(
        [string]$Status,
        $Reg,
        [int]$Context,
        [bool]$Thinking,
        [bool]$EnableVision,
        [string]$ErrorMessage = ""
    )
    $stateDir = Join-Path $ScriptDir "usage_data"
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $state = [ordered]@{
        status      = $Status
        model       = $Model
        label       = $Reg.label
        model_file  = $Reg.file
        context     = $Context
        thinking    = $Thinking
        vision      = $EnableVision
        updated_at  = (Get-Date).ToUniversalTime().ToString("o")
    }
    if ($ErrorMessage) { $state.error = $ErrorMessage }
    $statePath = Join-Path $stateDir "runtime_state.json"
    $tmpPath = "$statePath.tmp"
    $json = $state | ConvertTo-Json -Depth 4
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
    Move-Item -Force $tmpPath $statePath
}

function Test-LlmHealthy {
    # Probe /health inside the container so we detect readiness as soon as
    # llama-server responds, without waiting for Docker's healthcheck tick.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = docker exec llm-server curl -sf http://localhost:8888/health 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        $status = docker inspect --format '{{.State.Health.Status}}' llm-server 2>$null
        return $status -eq "healthy"
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Wait-LlmHealthy {
    param([int]$TimeoutSec = 300)
    if (Test-LlmHealthy) { return $true }

    Write-Info "Loading model into GPU/RAM (cold start can take several minutes)..."
    Write-Info "Live logs: docker compose -f `"$ComposeFile`" logs -f llm"

    $start = Get-Date
    $lastLogAt = [datetime]::MinValue
    $lastLogLine = ""

    while ($true) {
        if (Test-LlmHealthy) { return $true }
        if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSec) { return $false }

        $now = Get-Date
        if (($now - $lastLogAt).TotalSeconds -ge 15) {
            $lastLogAt = $now
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $line = docker compose -f $ComposeFile logs --tail 1 llm 2>$null | Select-Object -Last 1
                if ($line -and $line.Trim() -ne $lastLogLine) {
                    $lastLogLine = $line.Trim()
                    Write-Host ""
                    Write-Info $lastLogLine
                }
            } finally {
                $ErrorActionPreference = $prevEap
            }
        }

        Start-Sleep -Seconds 1
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }
}

function Get-ProcessStartTimeUtc {
    param([int]$ProcessId)
    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime()
    } catch {
        return $null
    }
}

function Stop-HostControllerProcesses {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*host_controller.py*" } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Ensure-HostController {
    $port = 8900
    $controller = Join-Path $ScriptDir "host_controller.py"
    if (-not (Test-Path $controller)) { return }

    $scriptMtime = (Get-Item $controller).LastWriteTimeUtc
    $running = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*host_controller.py*" })

    $stale = $false
    foreach ($proc in $running) {
        $startUtc = Get-ProcessStartTimeUtc -ProcessId $proc.ProcessId
        if ($startUtc -and $startUtc -lt $scriptMtime) { $stale = $true; break }
    }

    if ($stale -or $running.Count -gt 1) {
        Write-Info "Restarting host controller (code updated or duplicate processes)..."
        Stop-HostControllerProcesses
        Start-Sleep -Seconds 1
    } elseif ($running.Count -eq 1) {
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -eq 200) { return }
        } catch { }
    }

    Write-Info "Starting host controller on http://127.0.0.1:$port ..."
    Start-Process -FilePath "uv" -ArgumentList @("run", "python", $controller) -WorkingDirectory $ScriptDir -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -eq 200) {
                Write-Ok "Host controller ready (remote model switching enabled)"
                return
            }
        } catch { }
    }
    Write-Warn "Host controller did not start; remote /admin/reconcile will be unavailable"
}

function Stop-McpServerProcesses {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*mcp*server.py*" } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Ensure-McpServer {
    $port = 8901
    $server = Join-Path $ScriptDir "mcp\server.py"
    if (-not (Test-Path $server)) { return }

    $scriptMtime = (Get-Item $server).LastWriteTimeUtc
    $running = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*mcp*server.py*" })

    $stale = $false
    foreach ($proc in $running) {
        $startUtc = Get-ProcessStartTimeUtc -ProcessId $proc.ProcessId
        if ($startUtc -and $startUtc -lt $scriptMtime) { $stale = $true; break }
    }

    if ($stale -or $running.Count -gt 1) {
        Write-Info "Restarting MCP server (code updated or duplicate processes)..."
        Stop-McpServerProcesses
        Start-Sleep -Seconds 1
    } elseif ($running.Count -eq 1) {
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -eq 200) { return }
        } catch { }
    }

    Write-Info "Starting MCP server on http://127.0.0.1:$port/mcp ..."
    $reqFile = Join-Path $ScriptDir "mcp\requirements.txt"
    $uvArgs = @("run")
    if (Test-Path $reqFile) { $uvArgs += @("--with-requirements", $reqFile) }
    $uvArgs += @("python", $server)
    $logFile = Join-Path $ScriptDir "logs\mcp-server.log"
    $logDir = Split-Path $logFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $proc = Start-Process -FilePath "uv" -ArgumentList $uvArgs -WorkingDirectory $ScriptDir `
        -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" -PassThru
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -eq 200) {
                Write-Ok "MCP server ready (remote /mcp enabled)"
                return
            }
        } catch { }
    }
    $exited = $proc.HasExited
    $exitCode = if ($exited) { $proc.ExitCode } else { "still running" }
    Write-Warn "MCP server did not start (process exit: $exitCode). See logs\mcp-server.log"
    if ($exited) {
        $stderr = ""
        $errPath = "$logFile.err"
        if (Test-Path $errPath) { $stderr = (Get-Content $errPath -ErrorAction SilentlyContinue) -join "`n" }
        $stdout = ""
        if (Test-Path $logFile) { $stdout = (Get-Content $logFile -ErrorAction SilentlyContinue) -join "`n" }
        $detail = if ($stderr) { $stderr } elseif ($stdout) { $stdout } else { "no output captured" }
        $detail -split "`n" | Select-Object -First 15 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
    }
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

function Get-HfCacheDir {
    if ($env:HF_HOME) {
        $hubCache = Join-Path $env:HF_HOME "hub"
        if (Test-Path $hubCache) { return $hubCache }
    }
    $default = Join-Path $env:USERPROFILE ".cache\huggingface\hub"
    if (Test-Path $default) { return $default }
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
    $destPath = Join-Path $ScriptDir "models\$DestFile"

    if (Test-Path $destPath) {
        try {
            $null = [System.IO.File]::OpenRead((Get-Item $destPath -Force).FullName).Dispose()
            Write-Ok "$Label ready"
            return
        } catch {
            Write-Warn "Existing $Label unreadable, re-downloading..."
        }
    }

    $hf = Get-Command hf -ErrorAction SilentlyContinue
    if (-not $hf) { $hf = Get-Command huggingface-cli -ErrorAction SilentlyContinue }
    if (-not $hf) { throw "'hf' CLI not found. Run .\setup.ps1 first." }

    $token = Get-DotEnvValue "HF_TOKEN"
    if ($token -and $token -ne "hf_xxx" -and -not $env:HF_TOKEN) { $env:HF_TOKEN = $token }
    $env:PYTHONIOENCODING = "utf-8"
    $env:PYTHONUTF8 = "1"
    Remove-Item Env:TQDM_POSITION -ErrorAction SilentlyContinue
    Remove-Item Env:HF_HUB_ENABLE_HF_TRANSFER -ErrorAction SilentlyContinue
    Remove-Item Env:HF_HUB_DISABLE_PROGRESS_BARS -ErrorAction SilentlyContinue

    $cached = Find-HfCacheFile -Repo $Repo -Include $Include
    if ($cached) {
        Write-Info "Found $Label in HF cache, linking..."
        $ok = New-HardlinkOrCopy -LinkPath $destPath -TargetPath $cached.FullName
        if ($ok) {
            Write-Ok "$Label ready (from HF cache)"
            return
        }
    }

    Write-Info "Downloading $Label from $Repo ..."
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

    $cached = Find-HfCacheFile -Repo $Repo -Include $Include
    if (-not $cached) {
        throw "Download succeeded but no matching file in HF cache for $Label (pattern: $Include)"
    }

    $ok = New-HardlinkOrCopy -LinkPath $destPath -TargetPath $cached.FullName
    if ($ok) {
        Write-Ok "$Label ready (from HF cache)"
    } else {
        throw "Failed to link or copy $Label from HF cache"
    }
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
if (-not $Model) { $Model = $Config.default_model }
$resolved = Resolve-ModelId $Model
if (-not $resolved) {
    Write-Err "Unknown model '$Model'. Valid: $($ValidModelIds -join ', ')"
    exit 1
}
$Model = $resolved
$reg = $Config.models.$Model
if ($Context -le 0) { $Context = [int]$reg.context }
if (-not $KvCache) { $KvCache = if ($reg.kv_cache) { $reg.kv_cache } else { "q8_0" } }
$modelsDir = Join-Path $ScriptDir "models"
if (-not (Test-Path $modelsDir)) { New-Item -ItemType Directory -Path $modelsDir | Out-Null }

$modelPath  = Join-Path $modelsDir $reg.file
$mmprojPath = Join-Path $modelsDir $reg.mmproj_file

foreach ($p in @($modelPath, $mmprojPath)) {
    if (Test-Path $p) {
        $item = Get-Item $p -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $resolved = $p
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
            if ($resolved -ne $p -and (Test-Path $resolved)) {
                Remove-Item $p -Force -ErrorAction SilentlyContinue
                $null = fsutil hardlink create `"$p`" `"$resolved`" 2>&1
                if (-not (Test-Path $p)) {
                    Copy-Item -LiteralPath $resolved -Destination $p -Force
                }
            }
        }
    }
}

if (-not (Test-Path $modelPath)) {
    if ($NoDownload) { Write-Err "Model missing: $($reg.file) (remove -NoDownload to fetch it)"; exit 1 }
    Get-ModelFromHub -Repo $reg.repo -Include $reg.include -DestFile $reg.file -Label $reg.label
}

$enableVision = if ($null -ne $Vision) {
    if ($Vision -is [string]) { $Vision -notin @("false", "`$false", "0", "off", "no", "") }
    else { [bool]$Vision }
} else { $true }
if ($enableVision -and -not (Test-Path $mmprojPath) -and -not $NoDownload) {
    Get-ModelFromHub -Repo $reg.mmproj_repo -Include $reg.mmproj_include -DestFile $reg.mmproj_file -Label "vision projector"
}
if ($enableVision -and -not (Test-Path $mmprojPath)) {
    Write-Warn "Vision projector not available - running without vision"
    $enableVision = $false
}
$modelFile = Get-Item $modelPath -Force
if ($modelFile.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    $modelFile = Get-Item (Resolve-Path $modelPath -ErrorAction SilentlyContinue) -Force -ErrorAction SilentlyContinue
}
$modelGb = [math]::Round($modelFile.Length / 1GB, 2)
Write-Ok "$($reg.label) ($modelGb GB)"

# --- 3. Configure ------------------------------------------------------------
Write-Step "Configuration"

$logicalCpus = [Environment]::ProcessorCount
$threadsAuto = $Threads -le 0
if ($threadsAuto) {
    if     ($logicalCpus -ge 32) { $Threads = 20 }
    elseif ($logicalCpus -ge 16) { $Threads = 12 }
    else                         { $Threads = [math]::Max(4, [int][math]::Ceiling($logicalCpus / 2.0)) }
}

$isMoe = [bool]$reg.moe
$moeFlags = ""
if ($isMoe) {
    switch ($MoeOffload) {
        "auto" { $moeFlags = "--cpu-moe" }
        "all"  { $moeFlags = "--cpu-moe" }
        "off"  { $moeFlags = "" }
        default { if ($MoeOffload -match '^\d+$') { $moeFlags = "--n-cpu-moe $MoeOffload" } }
    }
    if ($Batch -eq 2048 -and $UBatch -eq 2048 -and $MoeOffload -ne "off") { $Batch = 4096; $UBatch = 4096 }
}

$mmprojFlags = if ($enableVision) { "--mmproj /models/$($reg.mmproj_file)" } else { "" }

Write-Info ("Vision:    " + $(if ($enableVision) { "on" } else { "off" }))
Write-Info ("Context:   $Context tokens" + $(if ($Parallel -gt 1) { " ($([int]($Context / $Parallel))/slot x $Parallel)" } else { "" }))
Write-Info ("Reasoning: " + $(if ($Thinking) { "on" } else { "off" }))
Write-Info ("Threads:   $Threads " + $(if ($threadsAuto) { "(auto from $logicalCpus CPUs)" } else { "(manual)" }))
Write-Info ("Batch/UB:  $Batch / $UBatch")
Write-Info ("KV cache:  $KvCache")
Write-Info ("MoE:       " + $(if ($isMoe) { if ($moeFlags) { "$MoeOffload (experts->CPU)" } else { "off (full GPU)" } } else { "n/a (dense)" }))

$loadFlags = if ($reg.load_flags) { $reg.load_flags } else { "" }

$env:MODEL_FILE        = $reg.file
$env:MMPROJ_FLAGS      = $mmprojFlags
$env:CONTEXT_SIZE      = $Context.ToString()
$env:KV_CACHE_TYPE     = $KvCache
$env:THREADS           = $Threads.ToString()
$env:BATCH_SIZE        = $Batch.ToString()
$env:UBATCH_SIZE       = $UBatch.ToString()
$env:N_PARALLEL        = $Parallel.ToString()
$env:REASONING         = if ($Thinking) { "on" } else { "off" }
$env:MOE_FLAGS         = $moeFlags
$env:LOAD_FLAGS        = $loadFlags
$env:EXTRA_LLAMA_FLAGS = $ExtraFlags
Write-Ok "Environment set"

# --- 4. Start / reconcile ----------------------------------------------------
Write-Step "Starting server"
Ensure-UsageDataStorage
Ensure-HostController
Ensure-McpServer
$prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    $out = docker compose -f $ComposeFile up -d 2>&1
    $exit = $LASTEXITCODE
} finally { $ErrorActionPreference = $prevEap }
$out | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
if ($exit -ne 0) { Write-Err "docker compose up failed (exit $exit)"; Write-RuntimeState -Status "failed" -Reg $reg -Context $Context -Thinking $Thinking -EnableVision $enableVision -ErrorMessage "docker compose up failed (exit $exit)"; exit 1 }
Write-Ok "Container reconciled"

# --- 5. Wait for health ------------------------------------------------------
Write-Step "Waiting for health"
$timeout = 300
if (-not (Wait-LlmHealthy -TimeoutSec $timeout)) {
    Write-Host ""
    Write-Err "Not healthy within ${timeout}s. Check: docker compose logs llm"
    Write-RuntimeState -Status "failed" -Reg $reg -Context $Context -Thinking $Thinking -EnableVision $enableVision -ErrorMessage "Health check timed out after ${timeout}s"
    exit 1
}
Write-Host ""
Write-Ok "Server is ready"
Write-RuntimeState -Status "ready" -Reg $reg -Context $Context -Thinking $Thinking -EnableVision $enableVision

# --- Banner ------------------------------------------------------------------
$localIp = Get-LocalIp
Write-Banner "SERVER RUNNING" "$($reg.label)"
Write-Host ""
Write-Host "  Local:  http://localhost:8899/v1" -ForegroundColor White
Write-Host "  LAN:    http://${localIp}:8899/v1" -ForegroundColor White
Write-Host ""
Write-Host "  Reasoning: $(if ($Thinking) { 'on' } else { 'off' })    Vision: $(if ($enableVision) { 'on' } else { 'off' })    Context: $Context" -ForegroundColor Gray
$apiKey = Get-DotEnvValue "LLAMA_API_KEY"
if ($apiKey) {
    Write-Host "  API key:   $apiKey" -ForegroundColor Gray
} else {
    Write-Host "  API key:   none (auth disabled - run .\setup.ps1 to generate one)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  .\run.ps1 -Stop   stop     |   docker compose logs -f   logs" -ForegroundColor DarkGray
Write-Host "  MCP endpoint      /mcp on :8899  all admin ops (list/switch/start/stop)" -ForegroundColor DarkGray

if ($NoFollow) {
    exit 0
}

# --- Stream logs (foreground) ------------------------------------------------
Write-Host ""
Write-Host "  [logs] Ctrl+C stops streaming; the server keeps running." -ForegroundColor DarkGray
Write-Host ""
docker compose -f $ComposeFile logs -f
