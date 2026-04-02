<#
.SYNOPSIS
    Start or restart the LLM server.
    Safe to run multiple times - kills old instance, frees port, starts fresh.

.DESCRIPTION
    Manages the llama-server lifecycle:
    - Kills any existing llama-server processes
    - Frees port 8899 if occupied
    - Launches llama-server with optimized flags
    - Waits for health check
    - Streams logs

.PARAMETER Model
    Which model to load: "9b" (default) or "35b"

.PARAMETER Restart
    Kill existing server before starting (default behavior)

.PARAMETER Context
    Context window size (default: 32768)

.PARAMETER NoThinking
    Disable thinking mode (default: true)

.EXAMPLE
    .\run.ps1                  # Start with 9B model
    .\run.ps1 -Model 35b       # Start with 35B MoE model
    .\run.ps1 -Restart         # Restart server
    .\run.ps1 -Context 16384   # Smaller context window
#>

[CmdletBinding()]
param(
    [ValidateSet("9b", "35b")]
    [string]$Model = "9b",

    [switch]$Restart,

    [ValidateSet(8192, 16384, 32768, 65536)]
    [int]$Context = 32768,

    [switch]$NoThinking = $true
)

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
$LogFile     = Join-Path $LogsDir "server.log"
$PidFile     = Join-Path $ScriptDir ".server.pid"

# ---------- helpers ----------

function Write-Step([string]$Msg) {
    Write-Host "`n=== $Msg" -ForegroundColor Cyan
}

function Write-Ok([string]$Msg) {
    Write-Host "  OK $Msg" -ForegroundColor Green
}

function Write-Warn([string]$Msg) {
    Write-Host "  -- $Msg" -ForegroundColor Yellow
}

function Write-Err([string]$Msg) {
    Write-Host "  !! $Msg" -ForegroundColor Red
}

function Write-Info([string]$Msg) {
    Write-Host "  -> $Msg" -ForegroundColor White
}

function Kill-ProcessOnPort([int]$Port) {
    $connections = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($connections) {
        foreach ($conn in $connections) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Warn "Port $Port held by $($proc.ProcessName) (PID $($proc.Id)) - killing"
                Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
        }
    }
}

function Kill-LlamaServer {
    $processes = Get-Process -Name "llama-server" -ErrorAction SilentlyContinue
    if ($processes) {
        foreach ($p in $processes) {
            Write-Warn "Stopping llama-server (PID $($p.Id))..."
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }

    if (Test-Path $PidFile) {
        $oldPid = Get-Content $PidFile -ErrorAction SilentlyContinue
        if ($oldPid) {
            $proc = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -eq "llama-server") {
                Write-Warn "Stopping llama-server via PID file (PID $oldPid)..."
                Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            }
        }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
}

function Wait-PortFree([int]$Port, [int]$TimeoutSec = 10) {
    $start = Get-Date
    while ((Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)) {
        if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSec) {
            Write-Err "Port $Port still in use after ${TimeoutSec}s"
            return $false
        }
        Start-Sleep -Milliseconds 200
    }
    return $true
}

function Wait-ServerReady([string]$Url, [int]$TimeoutSec = 60) {
    Write-Host "  Waiting for server to be ready..." -ForegroundColor Gray
    $start = Get-Date
    while ($true) {
        try {
            $response = Invoke-WebRequest -Uri "$Url/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
            if ($response.StatusCode -eq 200) {
                return $true
            }
        } catch {}
        if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSec) {
            return $false
        }
        Start-Sleep -Milliseconds 500
        Write-Host "." -NoNewline -ForegroundColor Gray
    }
}

function Get-LocalIp {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Ethernet*" -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
    if (-not $ip) {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Wi-Fi*" -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
    }
    if (-not $ip) {
        $ip = "127.0.0.1"
    }
    return $ip
}

# ---------- Validation ----------

Write-Step "LLM Server - Port $ServerPort"

if (-not (Test-Path $ServerExe)) {
    Write-Err "llama-server.exe not found at $ServerExe"
    Write-Info "Run .\setup.ps1 first"
    exit 1
}

$ModelFile = if ($Model -eq "35b") {
    $f = Get-ChildItem $ModelsDir -Filter "*35B-A3B*Q4_K_XL*" -ErrorAction SilentlyContinue
    if (-not $f) {
        $f = Get-ChildItem $ModelsDir -Filter "*35B-A3B*" -ErrorAction SilentlyContinue
    }
    $f
} else {
    $f = Get-ChildItem $ModelsDir -Filter "*9B*Q4_K_M*" -ErrorAction SilentlyContinue
    if (-not $f) {
        $f = Get-ChildItem $ModelsDir -Filter "*9B*" -ErrorAction SilentlyContinue
    }
    $f
}

if (-not $ModelFile) {
    Write-Err "No $Model model found in $ModelsDir"
    Write-Info "Run .\setup.ps1 to download models"
    exit 1
}

$ModelPath = $ModelFile[0].FullName
$ModelSize = [math]::Round($ModelFile[0].Length / 1GB, 2)
Write-Info "Model: $($ModelFile[0].Name) ($ModelSize GB)"

# ---------- Kill existing ----------

Write-Step "Cleaning up"
Kill-LlamaServer
Kill-ProcessOnPort $ServerPort

if (-not (Wait-PortFree $ServerPort)) {
    Write-Err "Could not free port $ServerPort"
    exit 1
}
Write-Ok "Port $ServerPort is free"

# ---------- Build command ----------

$chatTemplate = ""
if ($NoThinking) {
    $chatTemplate = '--chat-template-kwargs', '{"enable_thinking": false}'
}

$args = @(
    "-m", $ModelPath
    "-c", $Context.ToString()
    "-ctk", "q8_0"
    "-ctv", "q8_0"
    "-ngl", "99"
    "--host", "0.0.0.0"
    "--port", $ServerPort.ToString()
    "--flash-attn"
) + $chatTemplate

Write-Step "Starting server"
Write-Info "Command: llama-server.exe $($args -join ' ')"

if (-not (Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}

if (Test-Path $LogFile) {
    Clear-Content $LogFile
}

# ---------- Launch ----------

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ServerExe
$psi.Arguments = $args -join " "
$psi.WorkingDirectory = Split-Path $ServerExe
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$process = [System.Diagnostics.Process]::Start($psi)

$process.Id | Out-File $PidFile -Force

Write-Ok "Server started (PID $($process.Id))"

# ---------- Wait for ready ----------

$ready = Wait-ServerReady -Url "http://localhost:$ServerPort" -TimeoutSec 120

if (-not $ready) {
    Write-Err "Server did not become ready within 120s"
    Write-Info "Check log: $LogFile"
    exit 1
}

Write-Ok "Server is ready!"

# ---------- Print connection info ----------

$localIp = Get-LocalIp

Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green
Write-Host "  SERVER RUNNING" -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Local:        http://localhost:$ServerPort/v1" -ForegroundColor White
Write-Host "  LAN:          http://$localIp`:$ServerPort/v1" -ForegroundColor White
Write-Host "  Tailscale:    http://<tailscale-ip>`:$ServerPort/v1" -ForegroundColor White
Write-Host ""
Write-Host "  API Key:      any-string (not validated)" -ForegroundColor Gray
Write-Host "  Log file:     $LogFile" -ForegroundColor Gray
Write-Host "  PID:          $($process.Id)" -ForegroundColor Gray
Write-Host ""
Write-Host "  MacBook config:" -ForegroundColor Cyan
Write-Host "  export OPENAI_BASE_URL=http://$localIp`:$ServerPort/v1" -ForegroundColor Gray
Write-Host ""
Write-Host "  Stop server:    Stop-Process -Id $($process.Id) -Force" -ForegroundColor Gray
Write-Host "  Restart:        .\run.ps1 -Restart" -ForegroundColor Gray
Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green

# ---------- Stream logs ----------

Write-Host "`n[Server output - Ctrl+C to stop streaming, server keeps running]" -ForegroundColor DarkGray
Write-Host ""

try {
    while (-not $process.HasExited) {
        $line = $process.StandardOutput.ReadLine()
        if ($line) {
            Write-Host $line
            Add-Content $LogFile $line
        }
        $errLine = $process.StandardError.ReadLine()
        if ($errLine) {
            Write-Host $errLine -ForegroundColor Yellow
            Add-Content $LogFile "ERR: $errLine"
        }
        Start-Sleep -Milliseconds 100
    }
} catch [System.Management.Automation.RuntimeException] {
    # Stream ended - normal when process exits
}

if ($process.HasExited) {
    Write-Warn "Server exited with code $($process.ExitCode)"
    Write-Info "Check log: $LogFile"
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}
