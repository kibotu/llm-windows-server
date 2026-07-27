<#
.SYNOPSIS
    Test the MCP get_server_status tool over Streamable HTTP.

.EXAMPLE
    .\scripts\test-mcp-status.ps1
    .\scripts\test-mcp-status.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

$mcpUrl = Get-McpUrl
$session = New-McpSession -Url $mcpUrl -BaseHeaders (Get-McpHeaders)
$status = Invoke-McpTool -Url $mcpUrl -SessionHeaders $session.Headers -ToolName "get_server_status"

if ($Json) {
    @{
        mcp_url       = $mcpUrl
        server_info   = $session.ServerInfo
        server_status = $status
    } | ConvertTo-Json -Depth 8
    return
}

Write-Host "MCP:      $mcpUrl"
if ($session.ServerInfo) {
    Write-Host ("Server:   {0} v{1}" -f $session.ServerInfo.name, $session.ServerInfo.version)
}
Write-Host ""
Write-Host "get_server_status tool result:"

$rt = $status.runtime
if ($rt) {
    Write-Host ("  Model:    {0}" -f $(if ($rt.model) { $rt.model } else { "unknown" }))
    Write-Host ("  Label:    {0}" -f $(if ($rt.label) { $rt.label } else { "n/a" }))
    Write-Host ("  Status:   {0}" -f $(if ($rt.status) { $rt.status } else { "unknown" }))
    Write-Host ("  Context:  {0}" -f $(if ($rt.context) { $rt.context } else { "n/a" }))
}

$llm = $status.llm
if ($llm) {
    Write-Host ("  LLM:      healthy={0}" -f $llm.healthy)
}

$job = $status.job
if ($job) {
    Write-Host ("  Job:      {0}" -f $(if ($job.status) { $job.status } else { "n/a" }))
}
