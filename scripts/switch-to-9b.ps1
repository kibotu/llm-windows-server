<#
.SYNOPSIS
    Switch the llm-server to the lighter Qwen3.5-9B model.

.EXAMPLE
    .\scripts\switch-to-9b.ps1
    .\scripts\switch-to-9b.ps1 -Wait   # block until the model is loaded
#>
[CmdletBinding()]
param([switch]$Wait)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Switch-AdminModel -Model "qwen35-9b" -Context (Get-ModelDefaultContext "qwen35-9b") -Wait:$Wait
