<#
.SYNOPSIS
    Test the MCP list_models tool over Streamable HTTP.

.EXAMPLE
    .\scripts\test-mcp-list-models.ps1
    .\scripts\test-mcp-list-models.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

$mcpUrl = Get-McpUrl
$session = New-McpSession -Url $mcpUrl -BaseHeaders (Get-McpHeaders)
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
