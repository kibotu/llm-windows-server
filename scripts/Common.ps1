# Shared helpers for llm-server admin API scripts (Windows / PowerShell).

$Script:AdminConfigLoaded = $false

function Get-AdminRepoRoot {
    $root = Split-Path -Parent $PSScriptRoot
    if (-not (Test-Path (Join-Path $root "run.ps1"))) {
        throw "Could not locate repo root (expected run.ps1 next to scripts/)"
    }
    return $root
}

function Get-DotEnvValue {
    param(
        [string]$Key,
        [string]$EnvFile
    )
    if (-not (Test-Path $EnvFile)) { return $null }
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=\s*(.+)$" } | Select-Object -First 1
    if ($line -and $line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.+)$") {
        return $Matches[1].Trim()
    }
    return $null
}

function Initialize-AdminConfig {
    if ($Script:AdminConfigLoaded) { return }

    $repoRoot = Get-AdminRepoRoot
    $envFile = Join-Path $repoRoot ".env"

    if (-not $env:LLM_SERVER_URL) {
        $env:LLM_SERVER_URL = "http://127.0.0.1:8899"
    }
    $env:LLM_SERVER_URL = $env:LLM_SERVER_URL.TrimEnd("/")

    if (-not $env:LLAMA_ADMIN_KEY) {
        $env:LLAMA_ADMIN_KEY = Get-DotEnvValue -Key "LLAMA_ADMIN_KEY" -EnvFile $envFile
    }
    if (-not $env:LLAMA_ADMIN_KEY) {
        $env:LLAMA_ADMIN_KEY = Get-DotEnvValue -Key "LLAMA_API_KEY" -EnvFile $envFile
    }
    if (-not $env:LLAMA_ADMIN_KEY) {
        $env:LLAMA_ADMIN_KEY = $env:LLAMA_API_KEY
    }

    if (-not $env:LLM_SWITCH_POLL_INTERVAL) { $env:LLM_SWITCH_POLL_INTERVAL = "5" }
    if (-not $env:LLM_SWITCH_POLL_TIMEOUT) { $env:LLM_SWITCH_POLL_TIMEOUT = "600" }

    $Script:AdminConfigLoaded = $true
}

function Get-AdminHeaders {
    Initialize-AdminConfig
    $headers = @{ Accept = "application/json" }
    if ($env:LLAMA_ADMIN_KEY) {
        $headers.Authorization = "Bearer $($env:LLAMA_ADMIN_KEY)"
    }
    return $headers
}

function Invoke-AdminGet {
    param([string]$Path)

    Initialize-AdminConfig
    $uri = "$($env:LLM_SERVER_URL)$Path"
    try {
        return Invoke-RestMethod -Uri $uri -Method Get -Headers (Get-AdminHeaders) -TimeoutSec 30
    } catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        throw "GET $Path failed: $detail"
    }
}

function Invoke-AdminPost {
    param(
        [string]$Path,
        [hashtable]$Body
    )

    Initialize-AdminConfig
    $uri = "$($env:LLM_SERVER_URL)$Path"
    $json = $Body | ConvertTo-Json -Compress
    try {
        return Invoke-RestMethod -Uri $uri -Method Post -Headers (Get-AdminHeaders) `
            -ContentType "application/json" -Body $json -TimeoutSec 30
    } catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        throw "POST $Path failed: $detail"
    }
}

function Wait-AdminReady {
    Initialize-AdminConfig
    $pollInterval = [int]$env:LLM_SWITCH_POLL_INTERVAL
    $timeout = [int]$env:LLM_SWITCH_POLL_TIMEOUT
    $deadline = (Get-Date).AddSeconds($timeout)

    Write-Host "Waiting for model to become ready (timeout ${timeout}s)..." -ForegroundColor Gray

    while ((Get-Date) -lt $deadline) {
        $status = Invoke-AdminGet -Path "/admin/status"
        $runtimeStatus = $status.runtime.status
        $jobStatus = $status.job.status
        $llmHealthy = [bool]$status.llm.healthy

        if ($runtimeStatus -eq "ready" -and $llmHealthy) {
            return $status
        }
        if ($jobStatus -eq "failed" -or $runtimeStatus -eq "failed") {
            throw "Model switch failed: $($status | ConvertTo-Json -Depth 6 -Compress)"
        }

        Start-Sleep -Seconds $pollInterval
    }

    throw "Timed out after ${timeout}s waiting for model to become ready"
}

function Switch-AdminModel {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [int]$Context = 0,
        [switch]$Wait
    )

    Initialize-AdminConfig

    $body = @{
        model  = $Model
        cancel = $true
    }
    if ($Context -gt 0) {
        $body.context = $Context
    }

    Write-Host "Switching to $Model via $($env:LLM_SERVER_URL)/admin/reconcile ..." -ForegroundColor Cyan
    $accepted = Invoke-AdminPost -Path "/admin/reconcile" -Body $body
    $accepted | ConvertTo-Json -Depth 6 | Write-Host

    if (-not $Wait) {
        Write-Host "Switch started. Run .\scripts\llm-status.ps1 to check progress." -ForegroundColor Gray
        return $accepted
    }

    $final = Wait-AdminReady
    $label = $final.runtime.label
    if (-not $label) { $label = $final.runtime.model }
    $ctx = $final.runtime.context
    Write-Host "Ready: $label (context $ctx)" -ForegroundColor Green
    return $final
}

function Get-LocalRuntimeState {
    $path = Join-Path (Get-AdminRepoRoot) "usage_data\runtime_state.json"
    if (-not (Test-Path $path)) { return $null }
    try {
        return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Show-AdminStatus {
    param([switch]$Json)

    $status = Invoke-AdminGet -Path "/admin/status"
    $rt = $status.runtime
    if (-not $rt -or -not $rt.model) {
        $local = Get-LocalRuntimeState
        if ($local) { $rt = $local }
    }

    if ($Json) {
        if ($rt -and -not $status.runtime.model) {
            $status | Add-Member -NotePropertyName runtime -NotePropertyValue $rt -Force
        }
        $status | ConvertTo-Json -Depth 8
        return
    }

    Write-Host ("Server:     {0}" -f $(if ($rt.model) { $rt.model } else { "unknown" }))
    Write-Host ("Label:      {0}" -f $(if ($rt.label) { $rt.label } else { "n/a" }))
    Write-Host ("Status:     {0}" -f $(if ($rt.status) { $rt.status } else { "unknown" }))
    Write-Host ("Context:    {0}" -f $(if ($rt.context) { $rt.context } else { "n/a" }))
    Write-Host ("Thinking:   {0}" -f $(if ($null -ne $rt.thinking) { $rt.thinking } else { "n/a" }))
    Write-Host ("Vision:     {0}" -f $(if ($null -ne $rt.vision) { $rt.vision } else { "n/a" }))
    Write-Host ("Updated:    {0}" -f $(if ($rt.updated_at) { $rt.updated_at } else { "n/a" }))
    Write-Host ("LLM health: {0}" -f $status.llm.healthy)
    Write-Host ("Job:        {0}" -f $(if ($status.job.status) { $status.job.status } else { "n/a" }))
}
