<#
.SYNOPSIS
    Test the MCP list_models tool over Streamable HTTP.

.DESCRIPTION
    Exercises the full MCP client flow against :8899/mcp (initialize, session,
    tools/call). Uses LLAMA_ADMIN_KEY / LLAMA_API_KEY from the repo .env via
    Common.ps1. Requires the usage-tracker proxy and host MCP server to be running.

.EXAMPLE
    .\scripts\test-mcp-list-models.ps1
    .\scripts\test-mcp-list-models.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

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
        [string]$Body
    )
    try {
        return Invoke-WebRequest -Uri $Url -Method Post -Headers $Headers `
            -Body $Body -ContentType "application/json" -TimeoutSec 30 -UseBasicParsing
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
        Accept               = "application/json, text/event-stream"
        "Content-Type"       = "application/json"
        "mcp-session-id"     = $session
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
        [hashtable]$Arguments = @{}
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

    $resp = Invoke-McpPost -Url $Url -Headers $SessionHeaders -Body $body
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

Initialize-AdminConfig
$mcpUrl = "$($env:LLM_SERVER_URL)/mcp"
$headers = Get-AdminHeaders
$headers.Accept = "application/json, text/event-stream"

$session = New-McpSession -Url $mcpUrl -BaseHeaders $headers
$models = Invoke-McpTool -Url $mcpUrl -SessionHeaders $session.Headers -ToolName "list_models"

if ($Json) {
    @{
        mcp_url     = $mcpUrl
        server_info = $session.ServerInfo
        list_models = $models
    } | ConvertTo-Json -Depth 8
    return
}

Write-Host "MCP:      $mcpUrl"
if ($session.ServerInfo) {
    Write-Host ("Server:   {0} v{1}" -f $session.ServerInfo.name, $session.ServerInfo.version)
}
Write-Host ""
Write-Host "list_models tool result:"
foreach ($m in $models.models) {
    $ctx = if ($m.default_context) { $m.default_context } else { "n/a" }
    Write-Host ("  {0,-12} {1}" -f $m.id, $m.label)
    Write-Host ("               file: /models/{0}  context: {1}" -f $m.model_file, $ctx)
}
