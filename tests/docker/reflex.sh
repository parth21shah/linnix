#!/usr/bin/env bash
#
# reflex.sh - Linnix Guardian Wrapper
# 
# This script:
# 1. Starts cognitod in the background
# 2. Monitors its log output for circuit breaker events
# 3. Executes `docker pause` on the victim container when triggered
#
set -euo pipefail

# Configuration
LOG_FILE="/var/log/linnix-agent.log"
VICTIM_CONTAINER="linnix-victim"
TRIGGER_PATTERN="Circuit Breaker triggered|fork_storm|oom_risk"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Cleanup function
cleanup() {
    echo "[REFLEX] Shutting down..."
    if [[ -n "${AGENT_PID:-}" ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
        kill "$AGENT_PID" 2>/dev/null || true
    fi
    exit 0
}

trap cleanup SIGTERM SIGINT

# Function to pause the victim container
pause_victim() {
    local reason="$1"
    echo "[REFLEX] ⚠️  CIRCUIT BREAKER ACTIVATED: $reason"
    
    # Check if victim is running
    if docker ps --format '{{.Names}}' | grep -q "^${VICTIM_CONTAINER}$"; then
        echo "[REFLEX] 🛑 Pausing container: $VICTIM_CONTAINER"
        docker pause "$VICTIM_CONTAINER" || {
            echo "[REFLEX] ❌ Failed to pause $VICTIM_CONTAINER"
            return 1
        }
        echo "[REFLEX] ✅ Container $VICTIM_CONTAINER successfully paused"
        
        # Log container state
        docker ps -a --filter "name=$VICTIM_CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.State}}"
        
        # Optional: Send metrics
        echo "[REFLEX] Circuit breaker event recorded at $(date -Iseconds)"
    else
        echo "[REFLEX] ⚠️  Victim container not found or already stopped"
    fi
}

# Wait for Docker socket to be available
echo "[REFLEX] Waiting for Docker socket..."
timeout=30
while [[ $timeout -gt 0 ]]; do
    if docker info >/dev/null 2>&1; then
        echo "[REFLEX] ✅ Docker socket ready"
        break
    fi
    sleep 1
    ((timeout--))
done

if [[ $timeout -eq 0 ]]; then
    echo "[REFLEX] ❌ Docker socket not available after 30s"
    exit 1
fi

# Start cognitod in background
echo "[REFLEX] 🚀 Starting Linnix cognitod..."
/opt/linnix/cognitod \
    --config /etc/linnix/linnix.toml \
    --handler rules:/etc/linnix/rules.yaml \
    2>&1 | tee "$LOG_FILE" &

AGENT_PID=$!
echo "[REFLEX] Cognitod started with PID: $AGENT_PID"

# Give eBPF programs time to load
sleep 5

# Verify cognitod is still running
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    echo "[REFLEX] ❌ Cognitod failed to start. Check logs:"
    tail -n 50 "$LOG_FILE"
    exit 1
fi

echo "[REFLEX] 👀 Monitoring for circuit breaker events..."
echo "[REFLEX] Trigger patterns: $TRIGGER_PATTERN"

# Monitor logs for trigger events
tail -F "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "$line"
    
    # Check for circuit breaker triggers
    if echo "$line" | grep -Ei "$TRIGGER_PATTERN" >/dev/null; then
        # Extract reason from log line
        reason=$(echo "$line" | grep -oE "(fork_storm|oom_risk|cpu_spin|io_saturation)" | head -n1)
        reason=${reason:-"unknown"}
        
        # Trigger the circuit breaker
        pause_victim "$reason"
        
        # Note: We continue monitoring rather than exiting
        # This allows multiple incidents to be caught in a single test run
    fi
    
    # Check if cognitod crashed
    if ! kill -0 "$AGENT_PID" 2>/dev/null; then
        echo "[REFLEX] ❌ Cognitod process died unexpectedly"
        exit 1
    fi
done &

MONITOR_PID=$!

# Wait for signals
wait "$AGENT_PID"
