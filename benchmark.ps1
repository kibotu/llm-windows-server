<#
.SYNOPSIS
    Benchmark the LLM server throughput (tokens/second).

.PARAMETER Server
    Server hostname or IP (default: localhost)

.PARAMETER Port
    Server port (default: 8899)

.PARAMETER Tokens
    Number of tokens to generate per test (default: 200)

.PARAMETER Runs
    Number of benchmark runs (default: 3)

.EXAMPLE
    .\benchmark.ps1                     # Benchmark localhost
    .\benchmark.ps1 -Server 192.168.1.100 -Runs 5
#>

param(
    [string]$Server = "localhost",
    [int]$Port = 8899,
    [int]$Tokens = 200,
    [int]$Runs = 3
)

$baseUrl = "http://${Server}:${Port}"

function Write-Header([string]$Msg) { Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Write-Result([string]$Label, [string]$Value) { 
    Write-Host "  $Label`: " -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor White
}

Write-Host ""
Write-Host "LLM Server Benchmark" -ForegroundColor Cyan
Write-Host "===================="
Write-Host "  Server: $baseUrl"
Write-Host "  Tokens per run: $Tokens"
Write-Host "  Runs: $Runs"

# Check server health
try {
    $health = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 5
    if ($health.status -ne "ok") { throw "Server not healthy" }
} catch {
    Write-Host "`n  ERROR: Cannot connect to server at $baseUrl" -ForegroundColor Red
    Write-Host "  Make sure the server is running (.\run.ps1)" -ForegroundColor Yellow
    exit 1
}

# Get model info
try {
    $models = Invoke-RestMethod -Uri "$baseUrl/v1/models" -TimeoutSec 5
    $modelId = $models.data[0].id
    Write-Host "  Model: $modelId"
} catch {
    $modelId = "unknown"
}

Write-Host ""

# Benchmark prompts (varying complexity)
$prompts = @(
    @{
        name = "Code Generation"
        system = "You are a helpful coding assistant."
        user = "Write a Python function that implements binary search on a sorted list. Include docstring and type hints."
    },
    @{
        name = "Creative Writing"
        system = "You are a creative writer."
        user = "Write a short story about a robot learning to paint. Make it emotional and vivid."
    },
    @{
        name = "Reasoning"
        system = "You are a logical reasoning assistant."
        user = "A farmer has 17 sheep. All but 9 run away. How many sheep does the farmer have left? Explain your reasoning step by step."
    }
)

$allResults = @()

foreach ($prompt in $prompts) {
    Write-Header $prompt.name
    
    $runResults = @()
    
    for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "  Run $i/$Runs... " -NoNewline
        
        $body = @{
            model = "qwen"
            messages = @(
                @{ role = "system"; content = $prompt.system }
                @{ role = "user"; content = $prompt.user }
            )
            max_tokens = $Tokens
            temperature = 0.7
        } | ConvertTo-Json -Depth 3
        
        try {
            $start = Get-Date
            $response = Invoke-RestMethod -Uri "$baseUrl/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 120
            $elapsed = ((Get-Date) - $start).TotalSeconds
            
            $promptTokens = $response.usage.prompt_tokens
            $completionTokens = $response.usage.completion_tokens
            $totalTokens = $response.usage.total_tokens
            
            # Calculate speeds
            $tokensPerSec = [math]::Round($completionTokens / $elapsed, 1)
            $timeToFirstToken = 0  # Not available in non-streaming
            
            $runResults += [PSCustomObject]@{
                elapsed = $elapsed
                promptTokens = $promptTokens
                completionTokens = $completionTokens
                tokensPerSec = $tokensPerSec
            }
            
            Write-Host "$completionTokens tokens in $([math]::Round($elapsed, 2))s = " -NoNewline -ForegroundColor Gray
            Write-Host "$tokensPerSec tok/s" -ForegroundColor Green
            
        } catch {
            Write-Host "FAILED: $_" -ForegroundColor Red
        }
    }
    
    if ($runResults.Count -gt 0) {
        $avgTokPerSec = [math]::Round(($runResults | Measure-Object -Property tokensPerSec -Average).Average, 1)
        $maxTokPerSec = [math]::Round(($runResults | Measure-Object -Property tokensPerSec -Maximum).Maximum, 1)
        $minTokPerSec = [math]::Round(($runResults | Measure-Object -Property tokensPerSec -Minimum).Minimum, 1)
        $avgCompletionTokens = [math]::Round(($runResults | Measure-Object -Property completionTokens -Average).Average, 0)
        
        Write-Host "  -------------------------------" -ForegroundColor DarkGray
        Write-Result "Average" "$avgTokPerSec tok/s (min: $minTokPerSec, max: $maxTokPerSec)"
        Write-Result "Avg tokens generated" "$avgCompletionTokens"
        
        $allResults += [PSCustomObject]@{
            name = $prompt.name
            avgTokPerSec = $avgTokPerSec
            maxTokPerSec = $maxTokPerSec
            minTokPerSec = $minTokPerSec
        }
    }
}

# Streaming benchmark
Write-Header "Streaming (Time to First Token)"

$streamResults = @()
for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "  Run $i/$Runs... " -NoNewline
    
    $body = @{
        model = "qwen"
        messages = @(
            @{ role = "user"; content = "Write a haiku about programming." }
        )
        max_tokens = 50
        stream = $true
    } | ConvertTo-Json -Depth 3
    
    try {
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
        
        $ttft = $null
        $chunks = 0
        $totalContent = ""
        
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line -match "^data: (.+)$" -and $Matches[1] -ne "[DONE]") {
                if (-not $ttft) {
                    $ttft = ((Get-Date) - $start).TotalMilliseconds
                }
                $chunks++
                $json = $Matches[1] | ConvertFrom-Json
                if ($json.choices[0].delta.content) {
                    $totalContent += $json.choices[0].delta.content
                }
            }
        }
        
        $totalTime = ((Get-Date) - $start).TotalMilliseconds
        $reader.Close()
        $response.Close()
        
        $streamResults += [PSCustomObject]@{
            ttft = $ttft
            totalTime = $totalTime
            chunks = $chunks
        }
        
        Write-Host "TTFT: $([math]::Round($ttft, 0))ms, Total: $([math]::Round($totalTime, 0))ms, $chunks chunks" -ForegroundColor Green
        
    } catch {
        Write-Host "FAILED: $_" -ForegroundColor Red
    }
}

if ($streamResults.Count -gt 0) {
    $avgTtft = [math]::Round(($streamResults | Measure-Object -Property ttft -Average).Average, 0)
    $minTtft = [math]::Round(($streamResults | Measure-Object -Property ttft -Minimum).Minimum, 0)
    Write-Host "  -------------------------------" -ForegroundColor DarkGray
    Write-Result "Average TTFT" "${avgTtft}ms (best: ${minTtft}ms)"
}

# Summary
Write-Header "Summary"

$overallAvg = [math]::Round(($allResults | Measure-Object -Property avgTokPerSec -Average).Average, 1)
$overallMax = [math]::Round(($allResults | Measure-Object -Property maxTokPerSec -Maximum).Maximum, 1)

Write-Host ""
Write-Host "  Model: $modelId" -ForegroundColor White
Write-Host "  -------------------------------" -ForegroundColor DarkGray

foreach ($result in $allResults) {
    Write-Host "  $($result.name): " -NoNewline -ForegroundColor Gray
    Write-Host "$($result.avgTokPerSec) tok/s" -ForegroundColor White
}

Write-Host "  -------------------------------" -ForegroundColor DarkGray
Write-Host "  Overall Average: " -NoNewline -ForegroundColor Gray
Write-Host "$overallAvg tok/s" -ForegroundColor Green
Write-Host "  Peak: " -NoNewline -ForegroundColor Gray
Write-Host "$overallMax tok/s" -ForegroundColor Green

if ($streamResults.Count -gt 0) {
    Write-Host "  Time to First Token: " -NoNewline -ForegroundColor Gray
    Write-Host "${avgTtft}ms" -ForegroundColor Green
}

Write-Host ""
