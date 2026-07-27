<#
.SYNOPSIS
    Test the MCP list_tools tool over Streamable HTTP.

.EXAMPLE
    .\scripts\test-mcp-list-tools.ps1
    .\scripts\test-mcp-list-tools.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

$mcpUrl = Get-McpUrl
$session = New-McpSession -Url $mcpUrl -BaseHeaders (Get-McpHeaders)
$tools = Invoke-McpTool -Url $mcpUrl -SessionHeaders $session.Headers -ToolName "list_tools"

if ($Json) {
    @{
        mcp_url     = $mcpUrl
        server_info = $session.ServerInfo
        list_tools  = $tools
    } | ConvertTo-Json -Depth 8
    return
}

Write-Host "MCP:      $mcpUrl"
if ($session.ServerInfo) {
    Write-Host ("Server:   {0} v{1}" -f $session.ServerInfo.name, $session.ServerInfo.version)
}
Write-Host ""
Write-Host "Available tools ($($tools.count)):"
foreach ($t in $tools.tools) {
    Write-Host ("  {0,-18} {1}" -f $t.name, $t.description)
}
