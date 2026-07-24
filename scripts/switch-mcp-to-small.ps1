<#
.SYNOPSIS
    Switch the llm-server to the small model (Qwen3.5-9B) via MCP.

.EXAMPLE
    .\scripts\switch-mcp-to-small.ps1
    .\scripts\switch-mcp-to-small.ps1 -Wait   # block until the model is loaded
#>
[CmdletBinding()]
param([switch]$Wait)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Switch-McpModel -Model "qwen35-9b" -Context 128000 -Wait:$Wait
