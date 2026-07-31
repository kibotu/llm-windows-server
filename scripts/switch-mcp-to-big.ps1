<#
.SYNOPSIS
    Switch the llm-server to the big model (Qwen3.6-35B) via MCP.

.EXAMPLE
    .\scripts\switch-mcp-to-big.ps1
    .\scripts\switch-mcp-to-big.ps1 -Wait   # block until the model is loaded
#>
[CmdletBinding()]
param([switch]$Wait)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Switch-McpModel -Model "qwen36" -Context (Get-ModelDefaultContext "qwen36") -Wait:$Wait
