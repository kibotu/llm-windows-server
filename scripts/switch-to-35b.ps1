<#
.SYNOPSIS
    Switch the llm-server to Qwen3.6-35B-A3B.

.EXAMPLE
    .\scripts\switch-to-35b.ps1
    .\scripts\switch-to-35b.ps1 -Wait   # block until the model is loaded
#>
[CmdletBinding()]
param([switch]$Wait)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Switch-AdminModel -Model "qwen36" -Context 262144 -Wait:$Wait
