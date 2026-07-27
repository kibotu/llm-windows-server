<#
.SYNOPSIS
    Test the MCP start_server tool over Streamable HTTP.

.DESCRIPTION
    Starts the llm-server stack via the MCP start_server tool.
    Optionally specify a model; defaults to the last active model.

.EXAMPLE
    .\scripts\test-mcp-start.ps1
    .\scripts\test-mcp-start.ps1 -Model qwen36
    .\scripts\test-mcp-start.ps1 -Model qwen35-9b -Context 128000 -Json
#>
[CmdletBinding()]
param(
    [string]$Model,
    [int]$Context = 0,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

$mcpUrl = Get-McpUrl
$session = New-McpSession -Url $mcpUrl -BaseHeaders (Get-McpHeaders)

$args = @{}
if ($Model) { $args.model = $Model }
if ($Context -gt 0) { $args.context = $Context }

Write-Host "Starting server via MCP start_server..." -ForegroundColor Cyan
$result = Invoke-McpTool -Url $mcpUrl -SessionHeaders $session.Headers `
    -ToolName "start_server" -Arguments $args

if ($Json) {
    @{
        mcp_url     = $mcpUrl
        server_info = $session.ServerInfo
        start       = $result
    } | ConvertTo-Json -Depth 8
    return
}

Write-Host ""
Write-Host "start_server result:"
$result | ConvertTo-Json -Depth 6 | Write-Host

if ($result.status -eq "accepted") {
    Write-Host ""
    Write-Host "Server start accepted. Run .\scripts\test-mcp-status.ps1 to check progress." -ForegroundColor Green
}
