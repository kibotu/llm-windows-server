<#
.SYNOPSIS
    Switch the llm-server to the tiny model (Qwen3.5-4B) via MCP.

.EXAMPLE
    .\scripts\switch-mcp-to-tiny.ps1
    .\scripts\switch-mcp-to-tiny.ps1 -Wait   # block until the model is loaded
#>
[CmdletBinding()]
param([switch]$Wait)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Switch-McpModel -Model "qwen35-4b" -Context 96000 -Wait:$Wait
