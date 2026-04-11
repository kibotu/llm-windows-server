#!/bin/bash
# Shell script to run LLM server benchmarks
# Usage: ./run-benchmark.sh [quick|standard|stress|context-scaling|all]

set -e

# Default values
TEST_SUITE="${1:-standard}"
URL="${BENCHMARK_URL:-http://localhost:8899}"
OUTPUT="${BENCHMARK_OUTPUT:-benchmark_results.json}"
TIMEOUT="${BENCHMARK_TIMEOUT:-300}"
SETUP_128K="${SETUP_128K:-false}"
MONITOR_GPU="${MONITOR_GPU:-false}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

show_help() {
    cat << EOF
LLM Server Benchmark Runner

USAGE:
    ./run-benchmark.sh [OPTIONS] [TEST_SUITE]

TEST SUITES:
    quick              Quick smoke test (10 requests, ~30s)
    standard           Standard benchmark suite (~5-10 min)
    stress             Stress test with high load (~10-15 min)
    context-scaling    Test across context sizes (~15-20 min)
    all                Run all test suites (~30-45 min)

ENVIRONMENT VARIABLES:
    BENCHMARK_URL      Server URL (default: http://localhost:8899)
    BENCHMARK_OUTPUT   Output JSON file (default: benchmark_results.json)
    BENCHMARK_TIMEOUT  Request timeout in seconds (default: 300)
    SETUP_128K         Set to 'true' to configure 128k context
    MONITOR_GPU        Set to 'true' to enable GPU monitoring

EXAMPLES:
    # Run standard benchmark
    ./run-benchmark.sh standard

    # Setup 128k context and run stress test
    SETUP_128K=true ./run-benchmark.sh stress

    # Run all tests with GPU monitoring
    MONITOR_GPU=true ./run-benchmark.sh all

    # Custom server URL
    BENCHMARK_URL=http://192.168.1.100:8899 ./run-benchmark.sh standard

BEFORE RUNNING:
    1. Ensure Docker is running
    2. Start the LLM server: docker-compose up -d
    3. Install dependencies: pip install -r requirements-benchmark.txt

EOF
    exit 0
}

if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
fi

# Validate test suite
if [[ ! "$TEST_SUITE" =~ ^(quick|standard|stress|context-scaling|all)$ ]]; then
    echo -e "${RED}ERROR: Invalid test suite: $TEST_SUITE${NC}"
    echo "Valid options: quick, standard, stress, context-scaling, all"
    exit 1
fi

# Check if Python is available
if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
    echo -e "${RED}ERROR: Python not found. Please install Python 3.8 or higher.${NC}"
    exit 1
fi

PYTHON_CMD=$(command -v python3 || command -v python)

# Check if benchmark script exists
if [[ ! -f "benchmark.py" ]]; then
    echo -e "${RED}ERROR: benchmark.py not found in current directory.${NC}"
    exit 1
fi

# Setup 128k context if requested
if [[ "$SETUP_128K" == "true" ]]; then
    echo -e "\n${CYAN}=== Setting up 128k context configuration ===${NC}"
    
    if [[ ! -f ".env.128k" ]]; then
        echo -e "${RED}ERROR: .env.128k not found${NC}"
        exit 1
    fi
    
    # Backup existing .env if it exists
    if [[ -f ".env" ]]; then
        timestamp=$(date +%Y%m%d_%H%M%S)
        cp ".env" ".env.backup.$timestamp"
        echo -e "${YELLOW}Backed up existing .env to .env.backup.$timestamp${NC}"
    fi
    
    # Copy 128k configuration
    cp ".env.128k" ".env"
    echo -e "${GREEN}Copied .env.128k to .env${NC}"
    
    # Restart Docker containers
    echo -e "\n${CYAN}Restarting Docker containers...${NC}"
    docker-compose down
    docker-compose up -d
    
    echo -e "\n${CYAN}Waiting for server to be ready (30 seconds)...${NC}"
    sleep 30
    
    # Check health
    if curl -sf "$URL/health" > /dev/null 2>&1; then
        echo -e "${GREEN}Server is ready!${NC}"
    else
        echo -e "${YELLOW}WARNING: Server health check failed. Continuing anyway...${NC}"
    fi
fi

# Start GPU monitoring if requested
GPU_MONITOR_PID=""
if [[ "$MONITOR_GPU" == "true" ]]; then
    echo -e "\n${CYAN}=== Starting GPU monitoring ===${NC}"
    
    if command -v nvidia-smi &> /dev/null; then
        GPU_LOG="gpu_monitor_$(date +%Y%m%d_%H%M%S).log"
        nvidia-smi --query-gpu=timestamp,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.free,memory.total --format=csv -l 2 > "$GPU_LOG" 2>&1 &
        GPU_MONITOR_PID=$!
        echo -e "${GREEN}GPU monitoring started (PID: $GPU_MONITOR_PID)${NC}"
        echo -e "${YELLOW}Logging to: $GPU_LOG${NC}"
    else
        echo -e "${YELLOW}WARNING: nvidia-smi not found. GPU monitoring disabled.${NC}"
    fi
fi

# Cleanup function
cleanup() {
    if [[ -n "$GPU_MONITOR_PID" ]]; then
        echo -e "\n${CYAN}Stopping GPU monitoring...${NC}"
        kill $GPU_MONITOR_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Check if dependencies are installed
echo -e "\n${CYAN}=== Checking dependencies ===${NC}"
if ! $PYTHON_CMD -c "import aiohttp, psutil" 2>/dev/null; then
    echo -e "${YELLOW}Installing benchmark dependencies...${NC}"
    $PYTHON_CMD -m pip install -r requirements-benchmark.txt
fi

# Run benchmark
echo -e "\n${CYAN}=== Starting Benchmark ===${NC}"
echo -e "Test Suite: ${TEST_SUITE}"
echo -e "Server URL: ${URL}"
echo -e "Output File: ${OUTPUT}"
echo -e "Timeout: ${TIMEOUT} seconds"
echo ""

START_TIME=$(date +%s)

set +e
$PYTHON_CMD benchmark.py --test "$TEST_SUITE" --url "$URL" --output "$OUTPUT" --timeout "$TIMEOUT"
EXIT_CODE=$?
set -e

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_FMT=$(printf '%02d:%02d:%02d' $((DURATION/3600)) $((DURATION%3600/60)) $((DURATION%60)))

echo -e "\n${CYAN}=== Benchmark Complete ===${NC}"
echo -e "Duration: ${DURATION_FMT}"
echo -e "${GREEN}Results saved to: ${OUTPUT}${NC}"

if [[ -f "$OUTPUT" ]]; then
    echo -e "\n${YELLOW}To view results:${NC}"
    echo -e "  cat $OUTPUT | python3 -m json.tool"
fi

if [[ -n "$GPU_MONITOR_PID" ]] && [[ -f "$GPU_LOG" ]]; then
    echo -e "\n${YELLOW}GPU monitoring log:${NC}"
    echo -e "  tail -n 20 $GPU_LOG"
fi

exit $EXIT_CODE
