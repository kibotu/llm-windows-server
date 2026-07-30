<#
.SYNOPSIS
    Switch the llm-server to the tiny Qwen3.5-4B model.

.EXAMPLE
    .\scripts\switch-to-4b.ps1
    .\scripts\switch-to-4b.ps1 -Wait   # block until the model is loaded
#>
[CmdletBinding()]
param([switch]$Wait)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Switch-AdminModel -Model "qwen35-4b" -Context 128000 -Wait:$Wait
