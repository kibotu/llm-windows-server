<#
.SYNOPSIS
    Switch the llm-server to the Heretic Cerebellum model via MCP.

.EXAMPLE
    .\scripts\switch-mcp-to-heretic.ps1
    .\scripts\switch-mcp-to-heretic.ps1 -Wait   # block until the model is loaded
#>
[CmdletBinding()]
param([switch]$Wait)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Switch-McpModel -Model "heretic" -Context 262144 -Wait:$Wait
