<#
.SYNOPSIS
    Test the LLM server connectivity and response.

.PARAMETER Server
    Server hostname or IP (default: localhost)

.PARAMETER Port
    Server port (default: 8899)

.EXAMPLE
    .\test.ps1                            # Test localhost
    .\test.ps1 -Server 192.168.1.100      # Test remote server
    .\test.ps1 -Server mypc.tailscale.net # Test via Tailscale
#>

param(
    [string]$Server = "localhost",
    [int]$Port = 8899
)

$baseUrl = "http://${Server}:${Port}"

function Write-Ok([string]$Msg) { Write-Host "  OK " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Err([string]$Msg) { Write-Host "  FAIL " -ForegroundColor Red -NoNewline; Write-Host $Msg }
function Write-Test([string]$Msg) { Write-Host "`n>> $Msg" -ForegroundColor Cyan }

Write-Host "`n=== LLM Server Test ===" -ForegroundColor Cyan
Write-Host "  Target: $baseUrl"

# Test 1: Health check
Write-Test "Health check"
try {
    $health = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 5
    if ($health.status -eq "ok") {
        Write-Ok "Server is healthy"
    } else {
        Write-Err "Unexpected status: $($health.status)"
    }
} catch {
    Write-Err "Could not connect: $_"
    Write-Host "`n  Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  - Is the server running? (.\run.ps1)"
    Write-Host "  - Is the firewall open? (port $Port)"
    Write-Host "  - Is the IP correct? ($Server)"
    exit 1
}

# Test 2: Models endpoint
Write-Test "List models"
try {
    $models = Invoke-RestMethod -Uri "$baseUrl/v1/models" -TimeoutSec 5
    $modelId = $models.data[0].id
    Write-Ok "Model loaded: $modelId"
} catch {
    Write-Err "Could not list models: $_"
}

# Test 3: Simple completion
Write-Test "Chat completion (simple)"
try {
    $body = @{
        model = "qwen"
        messages = @(
            @{ role = "user"; content = "Reply with exactly one word: Hello" }
        )
        max_tokens = 10
        temperature = 0
    } | ConvertTo-Json -Depth 3
    
    $start = Get-Date
    $response = Invoke-RestMethod -Uri "$baseUrl/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
    $elapsed = ((Get-Date) - $start).TotalMilliseconds
    
    $content = $response.choices[0].message.content
    $tokens = $response.usage.completion_tokens
    Write-Ok "Response: `"$content`" (${tokens} tokens, ${elapsed}ms)"
} catch {
    Write-Err "Completion failed: $_"
}

# Test 4: Streaming
Write-Test "Chat completion (streaming)"
try {
    $body = @{
        model = "qwen"
        messages = @(
            @{ role = "user"; content = "Count from 1 to 5, one number per line" }
        )
        max_tokens = 50
        stream = $true
    } | ConvertTo-Json -Depth 3
    
    $start = Get-Date
    $request = [System.Net.HttpWebRequest]::Create("$baseUrl/v1/chat/completions")
    $request.Method = "POST"
    $request.ContentType = "application/json"
    $request.Timeout = 30000
    
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $request.ContentLength = $bytes.Length
    $stream = $request.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    
    $response = $request.GetResponse()
    $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
    
    $chunks = 0
    $fullContent = ""
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($line -match "^data: (.+)$" -and $Matches[1] -ne "[DONE]") {
            $chunks++
            $json = $Matches[1] | ConvertFrom-Json
            if ($json.choices[0].delta.content) {
                $fullContent += $json.choices[0].delta.content
            }
        }
    }
    $reader.Close()
    $response.Close()
    
    $elapsed = ((Get-Date) - $start).TotalMilliseconds
    $preview = ($fullContent -replace "`n", " ").Substring(0, [Math]::Min(50, $fullContent.Length))
    Write-Ok "Received $chunks chunks in ${elapsed}ms"
    Write-Host "       Preview: `"$preview...`"" -ForegroundColor Gray
} catch {
    Write-Err "Streaming failed: $_"
}

# Test 5: Tool calling (if supported)
Write-Test "Tool calling"
try {
    $body = @{
        model = "qwen"
        messages = @(
            @{ role = "user"; content = "What is 15 * 7? Use the calculator tool." }
        )
        tools = @(
            @{
                type = "function"
                function = @{
                    name = "calculator"
                    description = "Perform arithmetic calculations"
                    parameters = @{
                        type = "object"
                        properties = @{
                            expression = @{
                                type = "string"
                                description = "Math expression to evaluate"
                            }
                        }
                        required = @("expression")
                    }
                }
            }
        )
        max_tokens = 100
    } | ConvertTo-Json -Depth 10
    
    $response = Invoke-RestMethod -Uri "$baseUrl/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
    
    $toolCalls = $response.choices[0].message.tool_calls
    if ($toolCalls) {
        $funcName = $toolCalls[0].function.name
        $funcArgs = $toolCalls[0].function.arguments
        Write-Ok "Tool call: $funcName($funcArgs)"
    } else {
        $content = $response.choices[0].message.content
        Write-Host "  -- " -ForegroundColor Yellow -NoNewline
        Write-Host "No tool call, got text response instead"
    }
} catch {
    Write-Err "Tool calling failed: $_"
}

# Summary
Write-Host "`n=== Test Complete ===" -ForegroundColor Green
Write-Host "  Server: $baseUrl"
Write-Host "  Use this on your Mac:"
Write-Host "  export OPENAI_BASE_URL=$baseUrl/v1" -ForegroundColor Gray
Write-Host ""
