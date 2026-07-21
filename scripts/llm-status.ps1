<#
.SYNOPSIS
    Show the currently active llm-server model and health.

.EXAMPLE
    .\scripts\llm-status.ps1
    .\scripts\llm-status.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Show-AdminStatus -Json:$Json
