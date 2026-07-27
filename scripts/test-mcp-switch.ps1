<#
.SYNOPSIS
    Test the MCP switch_model tool over Streamable HTTP.

.DESCRIPTION
    Switches the loaded model via the MCP switch_model tool.
    Use -Wait to block until the model is fully loaded.

.EXAMPLE
    .\scripts\test-mcp-switch.ps1 -Model qwen35-9b
    .\scripts\test-mcp-switch.ps1 -Model qwen36 -Wait
    .\scripts\test-mcp-switch.ps1 -Model heretic -Context 262144 -Wait -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Model,
    [int]$Context = 0,
    [switch]$Wait,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

$mcpUrl = Get-McpUrl
$session = New-McpSession -Url $mcpUrl -BaseHeaders (Get-McpHeaders)

$args = @{
    model  = $Model
    cancel = $true
    wait   = [bool]$Wait
}
if ($Context -gt 0) { $args.context = $Context }

$timeout = if ($Wait) { [int]$env:LLM_SWITCH_POLL_TIMEOUT + 60 } else { 30 }

Write-Host "Switching to $Model via MCP switch_model (wait=$($Wait.IsPresent))..." -ForegroundColor Cyan
$result = Invoke-McpTool -Url $mcpUrl -SessionHeaders $session.Headers `
    -ToolName "switch_model" -Arguments $args -TimeoutSec $timeout

if ($Json) {
    @{
        mcp_url     = $mcpUrl
        server_info = $session.ServerInfo
        switch      = $result
    } | ConvertTo-Json -Depth 8
    return
}

Write-Host ""
$result | ConvertTo-Json -Depth 6 | Write-Host

if (-not $Wait) {
    Write-Host ""
    Write-Host "Switch started. Run .\scripts\test-mcp-status.ps1 to check progress." -ForegroundColor Gray
} else {
    $final = $result.final
    if ($final) {
        $rt = $final.runtime
        $label = if ($rt.label) { $rt.label } else { $rt.model }
        $ctx = if ($rt.context) { $rt.context } else { "n/a" }
        Write-Host ""
        Write-Host "Ready: $label (context $ctx)" -ForegroundColor Green
    }
}
