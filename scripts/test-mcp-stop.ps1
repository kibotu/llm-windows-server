<#
.SYNOPSIS
    Test the MCP stop_server tool over Streamable HTTP.

.DESCRIPTION
    Stops the llm-server stack (docker compose down) via the MCP stop_server tool.

.EXAMPLE
    .\scripts\test-mcp-stop.ps1
    .\scripts\test-mcp-stop.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

$mcpUrl = Get-McpUrl
$session = New-McpSession -Url $mcpUrl -BaseHeaders (Get-McpHeaders)

Write-Host "Stopping server via MCP stop_server..." -ForegroundColor Cyan
$result = Invoke-McpTool -Url $mcpUrl -SessionHeaders $session.Headers `
    -ToolName "stop_server" -TimeoutSec 90

if ($Json) {
    @{
        mcp_url     = $mcpUrl
        server_info = $session.ServerInfo
        stop        = $result
    } | ConvertTo-Json -Depth 8
    return
}

Write-Host ""
Write-Host "stop_server result:"
$result | ConvertTo-Json -Depth 6 | Write-Host

if ($result.status -eq "stopped") {
    Write-Host ""
    Write-Host "Server stopped successfully." -ForegroundColor Green
}
