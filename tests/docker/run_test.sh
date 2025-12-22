#!/usr/bin/env bash
#
# run_test.sh - Integration test runner for Linnix Guardian vs. Victim scenario
#
# This script orchestrates the full test:
# 1. Brings up the Docker Compose stack
# 2. Waits for eBPF programs to load
# 3. Triggers stress attacks on the victim
# 4. Verifies the guardian successfully paused the victim
#
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_TIMEOUT=120
STRESS_DURATION=30

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up test environment..."
    cd "$SCRIPT_DIR"
    docker-compose down -v 2>/dev/null || true
    rm -rf logs/
}

# Trap cleanup on exit
trap cleanup EXIT

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker not found. Please install Docker."
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        log_error "docker-compose not found. Please install docker-compose."
        exit 1
    fi
    
    # Check if running as root or with sufficient privileges
    if ! docker info &> /dev/null; then
        log_error "Cannot connect to Docker. Are you in the docker group or running as root?"
        exit 1
    fi
    
    # Check for kernel BTF support (required for eBPF)
    if [[ ! -f /sys/kernel/btf/vmlinux ]]; then
        log_warning "Kernel BTF not found at /sys/kernel/btf/vmlinux"
        log_warning "eBPF telemetry may run in degraded mode"
    fi
    
    log_success "Prerequisites check passed"
}

# Build and start services
start_services() {
    log_info "Building and starting Docker Compose stack..."
    cd "$SCRIPT_DIR"
    
    # Create log directory
    mkdir -p logs
    
    # Build the guardian image
    log_info "Building linnix-guardian image (this may take several minutes)..."
    docker-compose build --no-cache guardian
    
    # Start services
    log_info "Starting services..."
    docker-compose up -d
    
    log_success "Services started"
}

# Wait for eBPF programs to load
wait_for_ebpf() {
    log_info "Waiting for eBPF programs to load..."
    
    local timeout=$TEST_TIMEOUT
    local interval=5
    
    while [[ $timeout -gt 0 ]]; do
        # Check if cognitod is running
        if docker exec linnix-guardian pgrep -f cognitod > /dev/null 2>&1; then
            log_info "Cognitod process detected"
            
            # Check logs for eBPF load success
            if docker logs linnix-guardian 2>&1 | grep -qi "eBPF programs loaded\|tracepoint attached\|kprobe attached"; then
                log_success "eBPF programs loaded successfully"
                return 0
            fi
        fi
        
        sleep "$interval"
        ((timeout -= interval))
        log_info "Still waiting... ($timeout seconds remaining)"
    done
    
    log_error "Timeout waiting for eBPF programs to load"
    log_info "Guardian logs:"
    docker logs linnix-guardian 2>&1 | tail -n 50
    return 1
}

# Verify victim is running
verify_victim() {
    log_info "Verifying victim container is running..."
    
    if ! docker ps --format '{{.Names}}' | grep -q "^linnix-victim$"; then
        log_error "Victim container is not running"
        docker ps -a --filter "name=linnix-victim"
        return 1
    fi
    
    local status
    status=$(docker inspect -f '{{.State.Status}}' linnix-victim)
    
    if [[ "$status" != "running" ]]; then
        log_error "Victim container status: $status (expected: running)"
        return 1
    fi
    
    log_success "Victim container is running"
    return 0
}

# Trigger stress attack on victim
trigger_attack() {
    local attack_type="$1"
    
    log_info "Triggering $attack_type attack on victim container..."
    
    case "$attack_type" in
        memory)
            # Memory stress: allocate 90% of available memory
            log_info "Launching memory stress (90% allocation, ${STRESS_DURATION}s)"
            docker exec -d linnix-victim \
                stress-ng --vm 2 --vm-bytes 90% --timeout "${STRESS_DURATION}s" \
                2>&1
            ;;
        cpu)
            # CPU stress: spawn CPU workers
            log_info "Launching CPU stress (4 workers, ${STRESS_DURATION}s)"
            docker exec -d linnix-victim \
                stress-ng --cpu 4 --timeout "${STRESS_DURATION}s" \
                2>&1
            ;;
        fork)
            # Fork bomb simulation (limited)
            log_info "Launching fork bomb simulation (${STRESS_DURATION}s)"
            docker exec -d linnix-victim \
                stress-ng --fork 8 --timeout "${STRESS_DURATION}s" \
                2>&1
            ;;
        combined)
            # Combined attack
            log_info "Launching combined attack (${STRESS_DURATION}s)"
            docker exec -d linnix-victim \
                stress-ng --vm 1 --vm-bytes 85% --cpu 2 --fork 4 --timeout "${STRESS_DURATION}s" \
                2>&1
            ;;
        *)
            log_error "Unknown attack type: $attack_type"
            return 1
            ;;
    esac
    
    log_success "Attack triggered: $attack_type"
}

# Monitor for circuit breaker activation
monitor_circuit_breaker() {
    log_info "Monitoring for circuit breaker activation..."
    
    local timeout=60
    local check_interval=2
    
    while [[ $timeout -gt 0 ]]; do
        # Check if victim was paused
        local victim_status
        victim_status=$(docker inspect -f '{{.State.Status}}' linnix-victim 2>/dev/null || echo "not-found")
        
        if [[ "$victim_status" == "paused" ]]; then
            log_success "🎯 Circuit breaker activated! Victim container is PAUSED"
            return 0
        elif [[ "$victim_status" == "exited" ]]; then
            log_warning "Victim container exited (possible OOM kill)"
            return 2
        fi
        
        # Check guardian logs for circuit breaker messages
        if docker logs linnix-guardian 2>&1 | tail -n 20 | grep -qi "circuit breaker\|pausing container"; then
            log_info "Circuit breaker event detected in logs"
        fi
        
        sleep "$check_interval"
        ((timeout -= check_interval))
    done
    
    log_error "Timeout: Circuit breaker did not activate within 60 seconds"
    return 1
}

# Display test results
show_results() {
    log_info "========================================="
    log_info "Test Results"
    log_info "========================================="
    
    echo ""
    log_info "Container Status:"
    docker ps -a --filter "name=linnix" --format "table {{.Names}}\t{{.Status}}\t{{.State}}"
    
    echo ""
    log_info "Guardian Logs (last 30 lines):"
    docker logs linnix-guardian 2>&1 | tail -n 30
    
    echo ""
    log_info "Victim Logs (last 20 lines):"
    docker logs linnix-victim 2>&1 | tail -n 20
    
    echo ""
    if [[ -f "$SCRIPT_DIR/logs/linnix-agent.log" ]]; then
        log_info "Agent Log File (last 20 lines):"
        tail -n 20 "$SCRIPT_DIR/logs/linnix-agent.log"
    fi
}

# Main test execution
main() {
    log_info "========================================="
    log_info "Linnix Guardian Integration Test"
    log_info "========================================="
    
    # Step 1: Check prerequisites
    check_prerequisites
    
    # Step 2: Start services
    start_services
    
    # Step 3: Wait for eBPF to load
    if ! wait_for_ebpf; then
        log_error "Failed to load eBPF programs"
        show_results
        exit 1
    fi
    
    # Step 4: Verify victim is running
    if ! verify_victim; then
        log_error "Victim container verification failed"
        show_results
        exit 1
    fi
    
    # Allow stabilization
    log_info "Waiting 10 seconds for system to stabilize..."
    sleep 10
    
    # Step 5: Choose attack type (default: combined)
    ATTACK_TYPE="${1:-combined}"
    trigger_attack "$ATTACK_TYPE"
    
    # Step 6: Monitor for circuit breaker
    if monitor_circuit_breaker; then
        log_success "========================================="
        log_success "✅ TEST PASSED"
        log_success "Guardian successfully prevented crash"
        log_success "========================================="
        show_results
        exit 0
    else
        log_error "========================================="
        log_error "❌ TEST FAILED"
        log_error "Circuit breaker did not activate"
        log_error "========================================="
        show_results
        exit 1
    fi
}

# Run main function with attack type argument
main "${1:-combined}"
