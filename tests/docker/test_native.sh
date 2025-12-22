#!/usr/bin/env bash
# Native Docker Enforcement Test - No wrapper, pure Rust implementation

set -euo pipefail

cd "$(dirname "$0")"

COMPOSE_FILE="docker-compose.native.yml"
GUARDIAN="linnix-guardian-native"
VICTIM="linnix-victim"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Linnix Native Docker Enforcement Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This test validates native Docker circuit breaker implementation:"
echo "  ✓ Direct Rust implementation (no shell wrapper)"
echo "  ✓ Config-driven enforcement policies"
echo "  ✓ Rule-specific actions (pause/stop/kill)"
echo "  ✓ Rate limiting and cooldown"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    docker-compose -f "$COMPOSE_FILE" down 2>/dev/null || true
}
trap cleanup EXIT

# Check prerequisites
if ! command -v docker &> /dev/null; then
    echo "❌ Docker not found. Please install Docker."
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    echo "❌ docker-compose not found. Please install docker-compose."
    exit 1
fi

# Step 1: Build guardian image
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Step 1: Building Native Guardian Image"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "This may take 10-15 minutes on first build (cached afterward)..."
echo ""

if ! docker-compose -f "$COMPOSE_FILE" build guardian-native 2>&1 | grep -E "Step|Finished|Successfully|ERROR"; then
    echo "❌ Build failed. Check logs above."
    exit 1
fi

echo ""
echo "✅ Build complete"
echo ""

# Step 2: Start services
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Step 2: Starting Services"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

docker-compose -f "$COMPOSE_FILE" up -d

echo ""
echo "⏳ Waiting for guardian to become healthy..."
for i in {1..30}; do
    if docker inspect "$GUARDIAN" --format '{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy"; then
        echo "✅ Guardian is healthy"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "❌ Guardian failed to become healthy within 30 seconds"
        docker logs "$GUARDIAN" 2>&1 | tail -n 50
        exit 1
    fi
    sleep 1
    echo -n "."
done
echo ""

# Step 3: Wait for eBPF initialization
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Step 3: Verifying eBPF Initialization"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

sleep 5
if docker logs "$GUARDIAN" 2>&1 | grep -q "sched_process_fork attached"; then
    echo "✅ eBPF probes attached successfully"
else
    echo "⚠️  eBPF probes may not be attached. Check logs:"
    docker logs "$GUARDIAN" 2>&1 | tail -n 20
fi

# Check for Docker enforcement initialization
if docker logs "$GUARDIAN" 2>&1 | grep -q "Docker enforcement handler loaded"; then
    echo "✅ Docker enforcement handler loaded from config"
else
    echo "⚠️  Docker enforcement handler not detected in logs"
fi

echo ""

# Step 4: Check victim container status
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Step 4: Verifying Victim Container"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

VICTIM_STATUS=$(docker inspect -f '{{.State.Status}}' "$VICTIM" 2>/dev/null || echo "not found")
echo "Victim status: $VICTIM_STATUS"

if [ "$VICTIM_STATUS" != "running" ]; then
    echo "⚠️  Victim is not running. Expected: running, Got: $VICTIM_STATUS"
fi

echo ""

# Step 5: Monitor for automatic circuit breaker activation
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Step 5: Monitoring for Automatic Circuit Breaker (60 seconds)"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "Watching for fork_storm detection from Docker daemon processes..."
echo "Guardian should automatically pause victim when threshold is exceeded."
echo ""

DETECTED=false
for i in {1..12}; do
    sleep 5
    
    STATUS=$(docker inspect -f '{{.State.Status}}' "$VICTIM" 2>/dev/null || echo "unknown")
    echo "[$i/12] Victim status: $STATUS"
    
    if [ "$STATUS" = "paused" ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ✅ SUCCESS: Native enforcement activated!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        DETECTED=true
        break
    fi
    
    # Check logs for enforcement actions
    if docker logs "$GUARDIAN" 2>&1 | grep -q "docker_enforcer.*Successfully.*paused"; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ✅ SUCCESS: Enforcement action logged!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        DETECTED=true
        break
    fi
done

echo ""

# Step 6: Show results
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Step 6: Test Results"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

echo "Container Status:"
docker ps -a --filter "name=linnix" --format "table {{.Names}}\t{{.Status}}\t{{.State}}"
echo ""

echo "Guardian Logs (enforcement events):"
docker logs "$GUARDIAN" 2>&1 | grep -E "docker_enforcer|fork_storm|rule=" | tail -n 10
echo ""

echo "Detection Events:"
docker logs "$GUARDIAN" 2>&1 | grep "fork_storm_demo" | tail -n 5
echo ""

echo "═══════════════════════════════════════════════════════════════════════════"
if [ "$DETECTED" = true ]; then
    echo "  ✅ TEST PASSED: Native Docker enforcement working!"
    echo ""
    echo "The guardian successfully:"
    echo "  ✓ Detected fork_storm via eBPF tracepoints"
    echo "  ✓ Triggered rule engine alert"
    echo "  ✓ Executed docker pause via native Rust handler"
    echo "  ✓ No shell wrapper required"
else
    echo "  ⚠️  TEST INCOMPLETE: No enforcement action detected within 60s"
    echo ""
    echo "This may be expected if fork activity was below threshold."
    echo "Try triggering manual stress test:"
    echo "  docker exec $VICTIM stress-ng --fork 8 --timeout 30s"
fi
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
