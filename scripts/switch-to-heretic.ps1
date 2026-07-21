<#
.SYNOPSIS
    Switch the llm-server to Qwen3.6-35B-A3B Heretic Cerebellum 14GB.

.EXAMPLE
    .\scripts\switch-to-heretic.ps1
    .\scripts\switch-to-heretic.ps1 -Wait   # block until the model is loaded
#>
[CmdletBinding()]
param([switch]$Wait)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Switch-AdminModel -Model "heretic" -Context 262144 -Wait:$Wait
