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

function Get-McpUrl {
    Initialize-AdminConfig
    return "$($env:LLM_SERVER_URL)/mcp"
}

function Get-McpHeaders {
    $headers = Get-AdminHeaders
    $headers.Accept = "application/json, text/event-stream"
    return $headers
}

function Get-McpSseMessages {
    param([string]$Text)
    $messages = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.StartsWith("data: ")) {
            $messages += ($line.Substring(6) | ConvertFrom-Json)
        }
    }
    return $messages
}

function Invoke-McpPost {
    param(
        [string]$Url,
        [hashtable]$Headers,
        [string]$Body,
        [int]$TimeoutSec = 30
    )
    try {
        return Invoke-WebRequest -Uri $Url -Method Post -Headers $Headers `
            -Body $Body -ContentType "application/json" -TimeoutSec $TimeoutSec -UseBasicParsing
    } catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        throw "MCP POST $Url failed: $detail"
    }
}

function New-McpSession {
    param(
        [string]$Url,
        [hashtable]$BaseHeaders
    )

    $initBody = @{
        jsonrpc = "2.0"
        id      = 1
        method  = "initialize"
        params  = @{
            protocolVersion = "2025-06-18"
            capabilities    = @{}
            clientInfo      = @{ name = "llm-server-scripts"; version = "1" }
        }
    } | ConvertTo-Json -Depth 6 -Compress

    $resp = Invoke-McpPost -Url $Url -Headers $BaseHeaders -Body $initBody
    $session = $resp.Headers["mcp-session-id"]
    if (-not $session) {
        throw "MCP initialize did not return mcp-session-id. Body: $($resp.Content)"
    }

    $initMsgs = Get-McpSseMessages -Text $resp.Content
    $serverInfo = $null
    if ($initMsgs.Count -gt 0 -and $initMsgs[0].result.serverInfo) {
        $serverInfo = $initMsgs[0].result.serverInfo
    }

    $sessionHeaders = [ordered]@{
        Accept                 = "application/json, text/event-stream"
        "Content-Type"         = "application/json"
        "mcp-session-id"       = $session
        "MCP-Protocol-Version" = "2025-06-18"
    }
    foreach ($key in $BaseHeaders.Keys) {
        if ($key -notin $sessionHeaders.Keys) {
            $sessionHeaders[$key] = $BaseHeaders[$key]
        }
    }

    $initializedBody = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    Invoke-McpPost -Url $Url -Headers $sessionHeaders -Body $initializedBody | Out-Null

    return @{
        SessionId  = $session
        Headers    = $sessionHeaders
        ServerInfo = $serverInfo
    }
}

function Invoke-McpTool {
    param(
        [string]$Url,
        [hashtable]$SessionHeaders,
        [string]$ToolName,
        [hashtable]$Arguments = @{},
        [int]$TimeoutSec = 30
    )

    $body = @{
        jsonrpc = "2.0"
        id      = 2
        method  = "tools/call"
        params  = @{
            name      = $ToolName
            arguments = $Arguments
        }
    } | ConvertTo-Json -Depth 6 -Compress

    $resp = Invoke-McpPost -Url $Url -Headers $SessionHeaders -Body $body -TimeoutSec $TimeoutSec
    $messages = Get-McpSseMessages -Text $resp.Content
    if ($messages.Count -eq 0) {
        throw "MCP tools/call returned no SSE data: $($resp.Content)"
    }

    $result = $messages[0].result
    if ($messages[0].error) {
        throw "MCP tools/call error: $($messages[0].error | ConvertTo-Json -Compress)"
    }
    if ($result.isError) {
        throw "MCP tool '$ToolName' failed: $($result | ConvertTo-Json -Depth 6 -Compress)"
    }

    $text = $result.content | Where-Object { $_.type -eq "text" } | Select-Object -First 1 -ExpandProperty text
    if (-not $text) {
        return $result
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        return $text
    }
}

function Switch-McpModel {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [int]$Context = 0,
        [switch]$Wait,
        [switch]$Json
    )

    Initialize-AdminConfig
    $mcpUrl = Get-McpUrl
    $session = New-McpSession -Url $mcpUrl -BaseHeaders (Get-McpHeaders)

    $args = @{
        model  = $Model
        cancel = $true
        wait   = [bool]$Wait
    }
    if ($Context -gt 0) {
        $args.context = $Context
    }

    $timeout = if ($Wait) { [int]$env:LLM_SWITCH_POLL_TIMEOUT + 60 } else { 30 }

    Write-Host "Switching to $Model via $mcpUrl (MCP switch_model, wait=$($Wait.IsPresent)) ..." -ForegroundColor Cyan
    $result = Invoke-McpTool -Url $mcpUrl -SessionHeaders $session.Headers `
        -ToolName "switch_model" -Arguments $args -TimeoutSec $timeout

    if ($Json) {
        @{
            mcp_url     = $mcpUrl
            server_info = $session.ServerInfo
            switch      = $result
        } | ConvertTo-Json -Depth 8
        return $result
    }

    $result | ConvertTo-Json -Depth 6 | Write-Host

    if (-not $Wait) {
        Write-Host "Switch started. Run .\scripts\llm-status.ps1 to check progress." -ForegroundColor Gray
        return $result
    }

    $final = $result.final
    if ($final) {
        $rt = $final.runtime
        $label = if ($rt.label) { $rt.label } else { $rt.model }
        $ctx = if ($rt.context) { $rt.context } else { "n/a" }
        Write-Host "Ready: $label (context $ctx)" -ForegroundColor Green
    }
    return $result
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

function Enrich-RuntimeState {
    param($Runtime)

    if (-not $Runtime -or -not $Runtime.model) { return $Runtime }

    $needsEnrich = (-not $Runtime.label) -or (-not $Runtime.context) -or (-not $Runtime.model_file)
    if (-not $needsEnrich) { return $Runtime }

    try {
        $models = Invoke-AdminGet -Path "/admin/models"
        $match = $models.models | Where-Object { $_.id -eq $Runtime.model } | Select-Object -First 1
        if (-not $match) { return $Runtime }

        if (-not $Runtime.label) {
            $Runtime | Add-Member -NotePropertyName label -NotePropertyValue $match.label -Force
        }
        if (-not $Runtime.context) {
            $Runtime | Add-Member -NotePropertyName context -NotePropertyValue $match.default_context -Force
        }
        if (-not $Runtime.model_file) {
            $Runtime | Add-Member -NotePropertyName model_file -NotePropertyValue $match.model_file -Force
        }
    } catch { }

    return $Runtime
}

function Get-DisplayRuntimeStatus {
    param(
        $Runtime,
        $Job,
        [bool]$LlmHealthy
    )

    $runtimeStatus = if ($Runtime) { $Runtime.status } else { $null }
    $jobStatus = if ($Job) { $Job.status } else { $null }

    if ($runtimeStatus -eq "running" -or $jobStatus -eq "running") { return "running" }
    if ($LlmHealthy) {
        if ($jobStatus -eq "failed" -or $runtimeStatus -eq "failed") {
            return "ready (last switch failed)"
        }
        if ($runtimeStatus) { return $runtimeStatus }
        return "ready"
    }
    if ($runtimeStatus) { return $runtimeStatus }
    return "unknown"
}

function Show-AdminStatus {
    param([switch]$Json)

    $status = Invoke-AdminGet -Path "/admin/status"
    $rt = $status.runtime
    if (-not $rt -or -not $rt.model) {
        $local = Get-LocalRuntimeState
        if ($local) { $rt = $local }
    }
    $rt = Enrich-RuntimeState -Runtime $rt
    $llmHealthy = [bool]$status.llm.healthy
    $displayStatus = Get-DisplayRuntimeStatus -Runtime $rt -Job $status.job -LlmHealthy $llmHealthy

    if ($Json) {
        if ($rt -and -not $status.runtime.model) {
            $status | Add-Member -NotePropertyName runtime -NotePropertyValue $rt -Force
        }
        $status | Add-Member -NotePropertyName display_status -NotePropertyValue $displayStatus -Force
        $status | ConvertTo-Json -Depth 8
        return
    }

    Write-Host ("Server:     {0}" -f $(if ($rt.model) { $rt.model } else { "unknown" }))
    Write-Host ("Label:      {0}" -f $(if ($rt.label) { $rt.label } else { "n/a" }))
    Write-Host ("Status:     {0}" -f $displayStatus)
    Write-Host ("Context:    {0}" -f $(if ($rt.context) { $rt.context } else { "n/a" }))
    Write-Host ("Thinking:   {0}" -f $(if ($null -ne $rt.thinking) { $rt.thinking } else { "n/a" }))
    Write-Host ("Vision:     {0}" -f $(if ($null -ne $rt.vision) { $rt.vision } else { "n/a" }))
    Write-Host ("Updated:    {0}" -f $(if ($rt.updated_at) { $rt.updated_at } else { "n/a" }))
    Write-Host ("LLM health: {0}" -f $status.llm.healthy)
    Write-Host ("Job:        {0}" -f $(if ($status.job.status) { $status.job.status } else { "n/a" }))
    if ($status.job.error -and $status.job.status -eq "failed") {
        $errLine = ($status.job.error -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($errLine) {
            Write-Host ("Job error:  {0}" -f $errLine.Trim()) -ForegroundColor Yellow
        }
    }
}
