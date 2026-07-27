<#
.SYNOPSIS
    Run all MCP tool tests in sequence: list_models, get_server_status, switch_model.

.DESCRIPTION
    Initializes an MCP session and exercises every read-only tool.
    Does NOT call start/stop (destructive). Use test-mcp-start/stop individually.

.EXAMPLE
    .\scripts\test-mcp-all.ps1
    .\scripts\test-mcp-all.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

$mcpUrl = Get-McpUrl
Write-Host "Connecting to MCP: $mcpUrl" -ForegroundColor Cyan
$session = New-McpSession -Url $mcpUrl -BaseHeaders (Get-McpHeaders)

if ($session.ServerInfo) {
    Write-Host ("Server: {0} v{1}" -f $session.ServerInfo.name, $session.ServerInfo.version)
}
Write-Host ""

# --- list_models ---
Write-Host "=== list_models ===" -ForegroundColor Yellow
$models = Invoke-McpTool -Url $mcpUrl -SessionHeaders $session.Headers -ToolName "list_models"
foreach ($m in $models.models) {
    $ctx = if ($m.default_context) { $m.default_context } else { "n/a" }
    Write-Host ("  {0,-12} {1}  (context: {2})" -f $m.id, $m.label, $ctx)
}
Write-Host ""

# --- get_server_status ---
Write-Host "=== get_server_status ===" -ForegroundColor Yellow
$status = Invoke-McpTool -Url $mcpUrl -SessionHeaders $session.Headers -ToolName "get_server_status"
$rt = $status.runtime
if ($rt) {
    Write-Host ("  Model:   {0}" -f $(if ($rt.model) { $rt.model } else { "unknown" }))
    Write-Host ("  Status:  {0}" -f $(if ($rt.status) { $rt.status } else { "unknown" }))
    Write-Host ("  Context: {0}" -f $(if ($rt.context) { $rt.context } else { "n/a" }))
}
$llm = $status.llm
if ($llm) {
    Write-Host ("  LLM:     healthy={0}" -f $llm.healthy)
}
$job = $status.job
if ($job) {
    Write-Host ("  Job:     {0}" -f $(if ($job.status) { $job.status } else { "n/a" }))
}
Write-Host ""

Write-Host "All read-only MCP tests passed." -ForegroundColor Green
Write-Host "Use test-mcp-switch.ps1, test-mcp-start.ps1, test-mcp-stop.ps1 for write operations." -ForegroundColor Gray

if ($Json) {
    @{
        mcp_url       = $mcpUrl
        server_info   = $session.ServerInfo
        list_models   = $models
        server_status = $status
    } | ConvertTo-Json -Depth 8
}
