# PowerShell script to run LLM server benchmarks
# Usage: .\run-benchmark.ps1 [quick|standard|stress|context-scaling|all]

param(
    [Parameter(Position=0)]
    [ValidateSet("quick", "standard", "stress", "context-scaling", "all")]
    [string]$TestSuite = "standard",
    
    [Parameter()]
    [string]$Url = "http://localhost:8899",
    
    [Parameter()]
    [string]$Output = "benchmark_results.json",
    
    [Parameter()]
    [int]$Timeout = 300,
    
    [Parameter()]
    [switch]$Setup128k,
    
    [Parameter()]
    [switch]$MonitorGpu,
    
    [Parameter()]
    [switch]$Help
)

function Show-Help {
    Write-Host @"
LLM Server Benchmark Runner

USAGE:
    .\run-benchmark.ps1 [OPTIONS] [TEST_SUITE]

TEST SUITES:
    quick              Quick smoke test (10 requests, ~30s)
    standard           Standard benchmark suite (~5-10 min)
    stress             Stress test with high load (~10-15 min)
    context-scaling    Test across context sizes (~15-20 min)
    all                Run all test suites (~30-45 min)

OPTIONS:
    -Url <url>         Server URL (default: http://localhost:8899)
    -Output <file>     Output JSON file (default: benchmark_results.json)
    -Timeout <sec>     Request timeout in seconds (default: 300)
    -Setup128k         Configure server for 128k context before running
    -MonitorGpu        Start GPU monitoring in separate window
    -Help              Show this help message

EXAMPLES:
    # Run standard benchmark
    .\run-benchmark.ps1 standard

    # Setup 128k context and run stress test
    .\run-benchmark.ps1 stress -Setup128k

    # Run all tests with GPU monitoring
    .\run-benchmark.ps1 all -MonitorGpu

    # Custom server URL
    .\run-benchmark.ps1 standard -Url http://192.168.1.100:8899

BEFORE RUNNING:
    1. Ensure Docker is running
    2. Start the LLM server: docker-compose up -d
    3. Install dependencies: pip install -r requirements-benchmark.txt

"@
    exit 0
}

if ($Help) {
    Show-Help
}

# Check if Python is available
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Python not found. Please install Python 3.8 or higher." -ForegroundColor Red
    exit 1
}

# Check if benchmark script exists
if (-not (Test-Path "benchmark.py")) {
    Write-Host "ERROR: benchmark.py not found in current directory." -ForegroundColor Red
    exit 1
}

# Setup 128k context if requested
if ($Setup128k) {
    Write-Host "`n=== Setting up 128k context configuration ===" -ForegroundColor Cyan
    
    if (-not (Test-Path ".env.128k")) {
        Write-Host "ERROR: .env.128k not found" -ForegroundColor Red
        exit 1
    }
    
    # Backup existing .env if it exists
    if (Test-Path ".env") {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        Copy-Item ".env" ".env.backup.$timestamp"
        Write-Host "Backed up existing .env to .env.backup.$timestamp" -ForegroundColor Yellow
    }
    
    # Copy 128k configuration
    Copy-Item ".env.128k" ".env" -Force
    Write-Host "Copied .env.128k to .env" -ForegroundColor Green
    
    # Restart Docker containers
    Write-Host "`nRestarting Docker containers..." -ForegroundColor Cyan
    docker-compose down
    docker-compose up -d
    
    Write-Host "`nWaiting for server to be ready (30 seconds)..." -ForegroundColor Cyan
    Start-Sleep -Seconds 30
    
    # Check health
    try {
        $response = Invoke-WebRequest -Uri "$Url/health" -TimeoutSec 5 -ErrorAction Stop
        Write-Host "Server is ready!" -ForegroundColor Green
    } catch {
        Write-Host "WARNING: Server health check failed. Continuing anyway..." -ForegroundColor Yellow
    }
}

# Start GPU monitoring if requested
$gpuMonitorJob = $null
if ($MonitorGpu) {
    Write-Host "`n=== Starting GPU monitoring ===" -ForegroundColor Cyan
    
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $gpuMonitorJob = Start-Job -ScriptBlock {
            while ($true) {
                nvidia-smi --query-gpu=timestamp,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.free,memory.total --format=csv
                Start-Sleep -Seconds 2
            }
        }
        Write-Host "GPU monitoring started (Job ID: $($gpuMonitorJob.Id))" -ForegroundColor Green
        Write-Host "View with: Receive-Job $($gpuMonitorJob.Id)" -ForegroundColor Yellow
    } else {
        Write-Host "WARNING: nvidia-smi not found. GPU monitoring disabled." -ForegroundColor Yellow
    }
}

# Check if dependencies are installed
Write-Host "`n=== Checking dependencies ===" -ForegroundColor Cyan
$pipList = python -m pip list 2>$null
if ($pipList -notmatch "aiohttp" -or $pipList -notmatch "psutil") {
    Write-Host "Installing benchmark dependencies..." -ForegroundColor Yellow
    python -m pip install -r requirements-benchmark.txt
}

# Run benchmark
Write-Host "`n=== Starting Benchmark ===" -ForegroundColor Cyan
Write-Host "Test Suite: $TestSuite" -ForegroundColor White
Write-Host "Server URL: $Url" -ForegroundColor White
Write-Host "Output File: $Output" -ForegroundColor White
Write-Host "Timeout: $Timeout seconds" -ForegroundColor White
Write-Host ""

$startTime = Get-Date

try {
    python benchmark.py --test $TestSuite --url $Url --output $Output --timeout $Timeout
    $exitCode = $LASTEXITCODE
} catch {
    Write-Host "`nERROR: Benchmark failed: $_" -ForegroundColor Red
    $exitCode = 1
} finally {
    # Stop GPU monitoring if running
    if ($gpuMonitorJob) {
        Write-Host "`n=== GPU Monitoring Results ===" -ForegroundColor Cyan
        Receive-Job $gpuMonitorJob
        Stop-Job $gpuMonitorJob
        Remove-Job $gpuMonitorJob
    }
}

$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host "`n=== Benchmark Complete ===" -ForegroundColor Cyan
Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
Write-Host "Results saved to: $Output" -ForegroundColor Green

if (Test-Path $Output) {
    Write-Host "`nTo view results:" -ForegroundColor Yellow
    Write-Host "  Get-Content $Output | ConvertFrom-Json | ConvertTo-Json -Depth 10" -ForegroundColor White
}

exit $exitCode
