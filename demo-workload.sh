#!/bin/bash
# Demo workload generator for Linnix
# Creates realistic system activity to test monitoring and AI detection

set -e

echo "🎬 Starting Linnix Demo Workload..."
echo "This will generate system activity for monitoring demonstration."
echo

# Function to create CPU-intensive process
cpu_spinner() {
    echo "🔄 Starting CPU-intensive task..."
    # Run a CPU-intensive task for 30 seconds
    timeout 30s bash -c 'while true; do :; done' &
    CPU_PID=$!
    echo "   PID $CPU_PID using high CPU for 30 seconds"
}

# Function to create memory allocation
memory_allocator() {
    echo "💾 Starting memory allocation task..."
    # Allocate and hold memory for 20 seconds
    timeout 20s python3 -c "
import time
data = []
for i in range(100):
    # Allocate 10MB chunks
    data.append(bytearray(10 * 1024 * 1024))
    time.sleep(0.2)
time.sleep(10)
" &
    MEM_PID=$!
    echo "   PID $MEM_PID allocating memory for 20 seconds"
}

# Function to create process spawning
fork_storm() {
    echo "🍴 Starting process spawning demonstration..."
    # Create multiple short-lived processes
    for i in {1..20}; do
        (sleep 0.$i && echo "Process $i completed") &
    done
    echo "   Created 20 short-lived processes"
}

# Function to create file I/O activity  
file_io_test() {
    echo "📁 Starting file I/O activity..."
    # Create some file I/O
    timeout 15s bash -c '
        for i in {1..100}; do
            echo "Test data $i $(date)" >> /tmp/linnix-demo-$i.txt
            cat /tmp/linnix-demo-$i.txt > /dev/null
            rm -f /tmp/linnix-demo-$i.txt
            sleep 0.1
        done
    ' &
    IO_PID=$!
    echo "   PID $IO_PID generating file I/O for 15 seconds"
}

# Function to monitor the demo
monitor_demo() {
    echo
    echo "📊 While the demo runs, you can:"
    echo "   • Open dashboard: http://localhost:8080"
    echo "   • Watch live events: curl -N http://localhost:3000/stream"
    echo "   • Check processes: curl http://localhost:3000/processes | jq"
    echo "   • View insights: curl http://localhost:3000/insights | jq"
    echo
    
    # Show real-time process count
    for i in {1..30}; do
        PROC_COUNT=$(curl -s http://localhost:3000/processes 2>/dev/null | jq '. | length' 2>/dev/null || echo "N/A")
        echo "   Active processes: $PROC_COUNT | Time: ${i}s"
        sleep 1
    done
}

# Cleanup function
cleanup_demo() {
    echo
    echo "🧹 Cleaning up demo processes..."
    # Kill any remaining background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    # Remove any temp files
    rm -f /tmp/linnix-demo-*.txt 2>/dev/null || true
    echo "✅ Cleanup complete"
}

# Trap cleanup on exit
trap cleanup_demo EXIT

# Main demo sequence
main() {
    echo "Starting demo sequence..."
    echo "Duration: ~45 seconds"
    echo
    
    # Check if Linnix is running
    if ! curl -sf http://localhost:3000/healthz >/dev/null 2>&1; then
        echo "❌ Linnix doesn't appear to be running!"
        echo "Please run './setup-llm.sh' first"
        exit 1
    fi
    
    echo "✅ Linnix is running - starting workload generation"
    echo
    
    # Start different workloads with staggered timing
    cpu_spinner
    sleep 5
    
    memory_allocator  
    sleep 3
    
    fork_storm
    sleep 2
    
    file_io_test
    
    # Monitor while workloads run
    monitor_demo
    
    echo
    echo "🎉 Demo complete!"
    echo
    echo "🤖 The AI model should have detected some of this activity."
    echo "Check for insights at: http://localhost:8080 or run:"
    echo "   curl http://localhost:3000/insights | jq"
    echo
    echo "📈 View the full system state:"
    echo "   curl http://localhost:3000/system | jq"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi