<#
.SYNOPSIS
    Start the host-side model switcher API.

.DESCRIPTION
    Launches model_switcher.py on port 8898 so clients can switch models by
    triggering run.ps1 from an HTTP endpoint.

.PARAMETER Port
    Port for the control API (default: 8898).

.EXAMPLE
    .\start-control.ps1

.EXAMPLE
    .\start-control.ps1 -Port 8900
#>

param(
    [int]$Port = 8898
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Write-Step([string]$Msg) { Write-Host "`n=== $Msg" -ForegroundColor Cyan }
function Write-Ok([string]$Msg) { Write-Host "  OK $Msg" -ForegroundColor Green }
function Write-Err([string]$Msg) { Write-Host "  !! $Msg" -ForegroundColor Red }
function Write-Info([string]$Msg) { Write-Host "  -> $Msg" -ForegroundColor White }

Write-Step "Starting model switcher API"

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Err "Python not found in PATH. Install Python 3.10+ first."
    exit 1
}

try {
    python -c "import flask, requests" 2>$null
} catch {
    Write-Err "Missing Python dependencies. Install with: pip install flask requests"
    exit 1
}

$env:MODEL_SWITCHER_PORT = $Port.ToString()
Write-Info "Port: $Port"
Write-Info "Service URL: http://localhost:$Port"
Write-Info "SSE switch endpoint: POST http://localhost:$Port/switch"
Write-Info "Press Ctrl+C to stop"
Write-Host ""

python "$ScriptDir\model_switcher.py"

if ($LASTEXITCODE -ne 0) {
    Write-Err "model_switcher.py exited with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Ok "Model switcher stopped"
