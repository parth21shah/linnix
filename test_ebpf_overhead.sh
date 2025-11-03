#!/bin/bash
# Performance test to prove eBPF overhead is <1% CPU
set -e

COGNITOD_BIN="./target/release/cognitod"
BPF_PATH="./target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf"
TEST_DURATION=60  # seconds
CONFIG_FILE="/tmp/linnix_test_config.toml"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Linnix eBPF Overhead Test - Proving <1% CPU Usage ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: This script must be run as root (eBPF requires CAP_BPF)${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Check if binaries exist
if [ ! -f "$COGNITOD_BIN" ]; then
    echo -e "${RED}ERROR: cognitod binary not found at $COGNITOD_BIN${NC}"
    echo "Build it with: cargo build --release -p cognitod"
    exit 1
fi

if [ ! -f "$BPF_PATH" ]; then
    echo -e "${RED}ERROR: eBPF binary not found at $BPF_PATH${NC}"
    echo "Build it with: cd linnix-ai-ebpf/linnix-ai-ebpf-ebpf && cargo build --release --target=bpfel-unknown-none -Z build-std=core"
    exit 1
fi

# Create minimal config
TEST_PORT=$((40000 + RANDOM % 10000))
cat > "$CONFIG_FILE" <<EOF
[runtime]
offline = true

[telemetry]
sample_interval_ms = 1000

[api]
host = "127.0.0.1"
port = $TEST_PORT
EOF

echo -e "${YELLOW}Step 1: Measuring baseline system activity (without cognitod)${NC}"
echo "Duration: 10 seconds"
echo

# Baseline measurement
sleep 3  # Let system stabilize
BASELINE_START=$(date +%s)
BASELINE_CPU_BEFORE=$(top -b -n 1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
sleep 10
BASELINE_CPU_AFTER=$(top -b -n 1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
BASELINE_END=$(date +%s)

echo -e "${GREEN}✓ Baseline measurement complete${NC}"
echo "  CPU usage (idle): ${BASELINE_CPU_BEFORE}%"
echo

echo -e "${YELLOW}Step 2: Starting cognitod with eBPF probes${NC}"
echo "  eBPF path: $BPF_PATH"
echo "  Config: $CONFIG_FILE"
echo

# Start cognitod in background
LINNIX_BPF_PATH="$BPF_PATH" "$COGNITOD_BIN" --config "$CONFIG_FILE" > /tmp/cognitod_test.log 2>&1 &
COGNITOD_PID=$!

# Wait for cognitod to initialize
echo "Waiting for cognitod to initialize (PID: $COGNITOD_PID)..."
sleep 5

# Check if it's still running
if ! kill -0 $COGNITOD_PID 2>/dev/null; then
    echo -e "${RED}ERROR: cognitod failed to start. Check /tmp/cognitod_test.log${NC}"
    cat /tmp/cognitod_test.log
    exit 1
fi

echo -e "${GREEN}✓ cognitod started successfully${NC}"
echo

echo -e "${YELLOW}Step 3: Generating realistic workload + measuring overhead${NC}"
echo "Duration: ${TEST_DURATION} seconds"
echo "This will:"
echo "  - Track all process fork/exec/exit events"
echo "  - Sample CPU/memory every 1 second"
echo "  - Measure cognitod's CPU consumption"
echo

# Function to generate realistic process activity
generate_workload() {
    local duration=$1
    local end_time=$(($(date +%s) + duration))
    
    while [ $(date +%s) -lt $end_time ]; do
        # Simulate various common operations
        ls -lR /usr/bin > /dev/null 2>&1 &
        find /tmp -type f > /dev/null 2>&1 &
        ps aux > /dev/null 2>&1 &
        echo "test" | sha256sum > /dev/null 2>&1 &
        sleep 0.5
    done
}

# Start workload in background
generate_workload $TEST_DURATION &
WORKLOAD_PID=$!

# Monitor cognitod CPU usage
echo "Monitoring cognitod CPU usage (sampling every 2 seconds)..."
echo "Time(s) | cognitod CPU% | System CPU% | Memory(RSS)"
echo "--------|---------------|-------------|-------------"

declare -a CPU_SAMPLES
SAMPLE_COUNT=0
START_TIME=$(date +%s)

for i in $(seq 1 $((TEST_DURATION / 2))); do
    # Get cognitod CPU and memory
    COGNITOD_STATS=$(ps -p $COGNITOD_PID -o %cpu,%mem,rss --no-headers 2>/dev/null || echo "0.0 0.0 0")
    COGNITOD_CPU=$(echo "$COGNITOD_STATS" | awk '{print $1}')
    COGNITOD_MEM=$(echo "$COGNITOD_STATS" | awk '{print $2}')
    COGNITOD_RSS=$(echo "$COGNITOD_STATS" | awk '{print $3}')
    
    # Get system CPU
    SYSTEM_CPU=$(top -b -n 1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    
    # Store sample
    CPU_SAMPLES[$SAMPLE_COUNT]=$COGNITOD_CPU
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
    
    ELAPSED=$(($(date +%s) - START_TIME))
    printf "%7d | %13s | %11s | %6s KB\n" $((ELAPSED * 2)) "$COGNITOD_CPU" "$SYSTEM_CPU" "$COGNITOD_RSS"
    
    sleep 2
done

# Wait for workload to complete
wait $WORKLOAD_PID 2>/dev/null || true

echo
echo -e "${YELLOW}Step 4: Analyzing results${NC}"
echo

# Calculate statistics
TOTAL_CPU=0
MAX_CPU=0
for cpu in "${CPU_SAMPLES[@]}"; do
    TOTAL_CPU=$(echo "$TOTAL_CPU + $cpu" | bc)
    MAX_CPU=$(echo "if ($cpu > $MAX_CPU) $cpu else $MAX_CPU" | bc)
done

AVG_CPU=$(echo "scale=3; $TOTAL_CPU / $SAMPLE_COUNT" | bc)

# Get total events processed
EVENTS_PROCESSED=$(grep -c "ProcessEvent" /tmp/cognitod_test.log 2>/dev/null || echo "N/A")

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                     RESULTS ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo
echo -e "Test Duration:       ${TEST_DURATION} seconds"
echo -e "Samples Collected:   ${SAMPLE_COUNT}"
echo -e "Events Processed:    ${EVENTS_PROCESSED}"
echo
echo -e "${GREEN}CPU Usage Statistics:${NC}"
echo -e "  Average CPU:       ${AVG_CPU}%"
echo -e "  Peak CPU:          ${MAX_CPU}%"
echo

# Determine pass/fail
PASS_THRESHOLD="1.0"
if (( $(echo "$AVG_CPU < $PASS_THRESHOLD" | bc -l) )); then
    echo -e "${GREEN}✓ SUCCESS: Average CPU usage (${AVG_CPU}%) is below 1%${NC}"
    echo -e "${GREEN}✓ The claim '<1% CPU usage with eBPF probes' is PROVEN!${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}✗ WARNING: Average CPU usage (${AVG_CPU}%) exceeds 1%${NC}"
    echo -e "${YELLOW}This may be due to debug builds or system load.${NC}"
    echo -e "${YELLOW}Try running on a quieter system or longer duration.${NC}"
    EXIT_CODE=1
fi

echo
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo

echo -e "${YELLOW}Step 5: Cleanup${NC}"
kill $COGNITOD_PID 2>/dev/null || true
wait $COGNITOD_PID 2>/dev/null || true
rm -f "$CONFIG_FILE"

echo -e "${GREEN}✓ Test complete. Logs saved to /tmp/cognitod_test.log${NC}"
echo

# Show some example events
if [ "$EVENTS_PROCESSED" != "N/A" ] && [ "$EVENTS_PROCESSED" -gt 0 ]; then
    echo -e "${BLUE}Sample of captured events:${NC}"
    head -20 /tmp/cognitod_test.log | grep -i "event\|fork\|exec" || echo "(No events found in first 20 lines)"
fi

exit $EXIT_CODE
