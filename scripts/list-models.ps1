<#
.SYNOPSIS
    List all models exposed by the llm-server.

.DESCRIPTION
    Reads LLAMA_API_KEY / LLAMA_ADMIN_KEY from the repo .env (via Common.ps1).
    Shows switchable admin aliases and OpenAI-compatible /v1/models entries.

.EXAMPLE
    .\scripts\list-models.ps1
    .\scripts\list-models.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common.ps1"

Initialize-AdminConfig
$headers = Get-AdminHeaders
$base = $env:LLM_SERVER_URL

$admin = Invoke-AdminGet -Path "/admin/models"
try {
    $v1 = Invoke-RestMethod -Uri "$base/v1/models" -Method Get -Headers $headers -TimeoutSec 30
} catch {
    $detail = $_.Exception.Message
    if ($_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
    throw "GET /v1/models failed: $detail"
}

if ($Json) {
    @{
        server   = $base
        admin    = $admin
        v1_models = $v1
    } | ConvertTo-Json -Depth 8
    return
}

Write-Host "Server: $base"
Write-Host ""
Write-Host "Switchable aliases (/admin/models):"
foreach ($m in $admin.models) {
    $ctx = if ($m.default_context) { $m.default_context } else { "n/a" }
    Write-Host ("  {0,-12} {1}" -f $m.id, $m.label)
    Write-Host ("               file: /models/{0}  context: {1}" -f $m.model_file, $ctx)
}

Write-Host ""
Write-Host "OpenAI model IDs (/v1/models):"
foreach ($m in $v1.data) {
    $ctx = if ($m.meta.n_ctx) { $m.meta.n_ctx } else { "n/a" }
    Write-Host ("  {0}  (context: {1})" -f $m.id, $ctx)
}
