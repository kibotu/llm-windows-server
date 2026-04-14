<#
.SYNOPSIS
    Start or restart the LLM server via Docker.

.PARAMETER Model
    Which model to load: "9b" (default), "35b", "gemma312" (Gemma 3 12B IT), or "gemma426ba4b" (Gemma 4 26B-A4B IT)

.PARAMETER Restart
    Force restart the container

.PARAMETER Context
    Context window size (default: 32768)

.PARAMETER Thinking
    Enable thinking/reasoning mode (default: false)

.PARAMETER Stop
    Stop the server

.EXAMPLE
    .\run.ps1                  # Start with 9B model
    .\run.ps1 -Model 35b       # Start with 35B MoE model
    .\run.ps1 -Model gemma312  # Gemma 3 12B IT (.\setup.ps1 -IncludeGemma312)
    .\run.ps1 -Model gemma426ba4b # Gemma 4 26B-A4B IT (.\setup.ps1 -IncludeGemma426BA4B)
    .\run.ps1 -Restart         # Restart server
    .\run.ps1 -Stop            # Stop server
#>

param(
    [ValidateSet("9b", "35b", "gemma312", "gemma426ba4b")]
    [string]$Model = "9b",

    [switch]$Restart,

    [int]$Context = 32768,

    [switch]$Thinking,

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

# Handle stop
if ($Stop) {
    Write-Step "Stopping server"
    docker compose -f "$ScriptDir\docker-compose.yml" down 2>&1 | Out-Null
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
    $f = Get-ChildItem "$ScriptDir\models" -Filter "*35B-A3B*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf" }
} elseif ($Model -eq "gemma312") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "gemma-3-12b-it-Q4_K_M.gguf" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "gemma-3-12b-it-Q4_K_M.gguf" }
} elseif ($Model -eq "gemma426ba4b") {
    $f = Get-ChildItem "$ScriptDir\models" -Filter "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.Name } else { "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" }
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
Write-Info "Model: $ModelFile ($ModelSize GB)"
Write-Info "Context: $Context tokens"
Write-Info "Reasoning: $(if ($Thinking) { 'on' } else { 'off' })"

# Set environment for docker-compose
$env:MODEL_FILE = $ModelFile
$env:CONTEXT_SIZE = $Context.ToString()
$env:REASONING = if ($Thinking) { "on" } else { "off" }

# Restart if requested or already running
if ($Restart) {
    Write-Step "Restarting server"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        docker compose -f "$ScriptDir\docker-compose.yml" down 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# Start container
Write-Step "Starting server"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $composeOutput = docker compose -f "$ScriptDir\docker-compose.yml" up -d 2>&1
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

# Wait for health check
Write-Host "  Waiting for server to be ready..." -ForegroundColor Gray
$timeout = 180
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
Write-Host "  .\run.ps1 -Model gemma312 # Gemma 3 12B (after -IncludeGemma312)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Model gemma426ba4b # Gemma 4 26B-A4B (after -IncludeGemma426BA4B)" -ForegroundColor Gray
Write-Host "  .\run.ps1 -Restart        # Restart server" -ForegroundColor Gray
Write-Host "  docker compose logs -f    # Stream logs" -ForegroundColor Gray
Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green

# Stream logs
Write-Host "`n[Container logs - Ctrl+C to stop streaming, server keeps running]" -ForegroundColor DarkGray
Write-Host ""

docker compose -f "$ScriptDir\docker-compose.yml" logs -f
