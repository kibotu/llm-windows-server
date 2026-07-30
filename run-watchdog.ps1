<#
.SYNOPSIS
    Watchdog wrapper for run.ps1 — restarts the server on crash or failure.

.DESCRIPTION
    Runs run.ps1 in a loop. If it exits with a non-zero code (crash, Docker
    failure, health timeout), the watchdog waits a configurable delay and
    relaunches. Ctrl+C on run.ps1 only stops log streaming (containers keep
    running); the watchdog detects exit 0 and stays idle until the next failure.

    Safe to leave running in a terminal or as a scheduled task.

.PARAMETER Model
    Forwarded to run.ps1 (default: qwen36).

.PARAMETER Vision
    Enable/disable the vision projector (forwarded to run.ps1).

.PARAMETER Thinking
    Enable/disable reasoning (forwarded to run.ps1).

.PARAMETER Context
    Override context size (forwarded to run.ps1; 0 = use model default).

.PARAMETER Delay
    Seconds to wait between restart attempts (default: 15).

.PARAMETER MaxRetries
    Maximum consecutive failures before giving up. 0 = unlimited (default: 0).

.EXAMPLE
    .\run-watchdog.ps1                                    # default model, unlimited retries
    .\run-watchdog.ps1 -Model qwen35-4b                   # tiny model with auto-restart
    .\run-watchdog.ps1 -Model qwen35-4b -Vision:$false    # tiny, no vision
    .\run-watchdog.ps1 -Delay 30 -MaxRetries 5            # give up after 5 consecutive failures
#>

[CmdletBinding()]
param(
    [ValidateSet("qwen36", "heretic", "qwen35-9b", "qwen35-4b")]
    [string]$Model = "qwen36",

    [object]$Vision = $null,

    [object]$Thinking = $null,

    [int]$Context = 0,

    [ValidateRange(1, 600)]
    [int]$Delay = 15,

    [ValidateRange(0, 1000)]
    [int]$MaxRetries = 0,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RunScript = Join-Path $ScriptDir "run.ps1"

if (-not (Test-Path $RunScript)) {
    Write-Host "[watchdog] run.ps1 not found at $RunScript" -ForegroundColor Red
    exit 1
}

$consecutiveFailures = 0

function Write-Watchdog {
    param([string]$Msg, [string]$Color = "DarkYellow")
    $ts = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$ts watchdog] $Msg" -ForegroundColor $Color
}

function Build-RunArgs {
    $runArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $RunScript, "-Model", $Model)
    if ($null -ne $Vision) {
        if ([bool]$Vision) { $runArgs += "-Vision"; $runArgs += "`$true" }
        else               { $runArgs += "-Vision"; $runArgs += "`$false" }
    }
    if ($null -ne $Thinking) {
        if ([bool]$Thinking) { $runArgs += "-Thinking"; $runArgs += "`$true" }
        else                 { $runArgs += "-Thinking"; $runArgs += "`$false" }
    }
    if ($Context -gt 0) {
        $runArgs += "-Context"; $runArgs += $Context.ToString()
    }
    if ($ExtraArgs) { $runArgs += $ExtraArgs }
    return $runArgs
}

while ($true) {
    $runArgs = Build-RunArgs
    $displayArgs = ($runArgs | Select-Object -Skip 5) -join " "
    Write-Watchdog "Starting run.ps1 $displayArgs" "Cyan"

    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $runArgs `
        -WorkingDirectory $ScriptDir -NoNewWindow -PassThru -Wait

    $exitCode = $proc.ExitCode

    if ($exitCode -eq 0) {
        $consecutiveFailures = 0
        Write-Watchdog "run.ps1 exited cleanly (code 0). Server is running in Docker." "Green"
        Write-Watchdog "Monitoring Docker containers..."

        while ($true) {
            Start-Sleep -Seconds 30
            $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            try {
                $health = docker inspect --format '{{.State.Health.Status}}' llm-server 2>$null
                $running = docker inspect --format '{{.State.Running}}' llm-server 2>$null
            } finally { $ErrorActionPreference = $prevEap }

            if ($running -ne "true") {
                Write-Watchdog "Container llm-server is not running — restarting in ${Delay}s..." "Yellow"
                break
            }
            if ($health -eq "unhealthy") {
                Write-Watchdog "Container llm-server is unhealthy — restarting in ${Delay}s..." "Yellow"
                break
            }
        }
    } else {
        $consecutiveFailures++
        Write-Watchdog "run.ps1 failed (exit code $exitCode, attempt $consecutiveFailures)" "Red"

        if ($MaxRetries -gt 0 -and $consecutiveFailures -ge $MaxRetries) {
            Write-Watchdog "Giving up after $MaxRetries consecutive failures." "Red"
            exit 1
        }
    }

    Write-Watchdog "Restarting in ${Delay}s... (Ctrl+C to stop watchdog)" "DarkYellow"
    Start-Sleep -Seconds $Delay
}
