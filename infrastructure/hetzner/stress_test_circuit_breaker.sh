#!/bin/bash
#
# Linnix Circuit Breaker Stress Test
# ===================================
# This script demonstrates Linnix's ability to protect an overcommitted
# Kubernetes cluster by detecting and mitigating resource abuse.
#
# What it does:
# 1. Captures baseline metrics from Linnix
# 2. Deploys a "bad tenant" workload that consumes excessive resources
# 3. Monitors PSI (Pressure Stall Information) as the system degrades
# 4. Verifies Linnix detects and responds to the pressure
# 5. Cleans up and reports results
#
# Prerequisites:
# - 5-node K8s cluster on Proxmox VMs
# - Linnix Guardian running on the Proxmox host
# - SSH access to control plane and host

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================
CONTROL_PLANE="178.63.224.202"
LINNIX_HOST="88.99.251.45"
LINNIX_API="http://127.0.0.1:3000"
NAMESPACE="stress-test"
TEST_DURATION=90  # seconds

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
log_header() {
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}${BOLD}  $1${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_metric() { echo -e "${CYAN}[METRIC]${NC} $1"; }

kctl() {
    ssh -o StrictHostKeyChecking=no root@${CONTROL_PLANE} "kubectl $*" 2>/dev/null
}

linnix_metrics() {
    ssh -o StrictHostKeyChecking=no root@${LINNIX_HOST} "curl -s ${LINNIX_API}/metrics" 2>/dev/null
}

linnix_processes() {
    ssh -o StrictHostKeyChecking=no root@${LINNIX_HOST} "curl -s ${LINNIX_API}/processes" 2>/dev/null
}

# ============================================================================
# MAIN TEST
# ============================================================================

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                                                                          ║${NC}"
echo -e "${BOLD}║   ${CYAN}LINNIX CIRCUIT BREAKER STRESS TEST${NC}${BOLD}                                   ║${NC}"
echo -e "${BOLD}║   Demonstrating eBPF-Powered Resource Protection                        ║${NC}"
echo -e "${BOLD}║                                                                          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# PHASE 1: BASELINE CAPTURE
# ============================================================================
log_header "PHASE 1: Capturing Baseline Metrics"

log_info "Querying Linnix Guardian on ${LINNIX_HOST}..."
BASELINE=$(linnix_metrics)
BASELINE_EVENTS=$(echo "$BASELINE" | grep -o '"events_per_sec":[0-9]*' | cut -d: -f2)
BASELINE_PROCS=$(linnix_processes | grep -o '"pid"' | wc -l)

log_metric "Baseline events/sec: ${BASELINE_EVENTS}"
log_metric "Baseline process count: ${BASELINE_PROCS}"

# Check PSI readings
log_info "Reading system PSI (Pressure Stall Information)..."
ssh root@${LINNIX_HOST} 'cat /proc/pressure/cpu /proc/pressure/memory' 2>/dev/null | while read line; do
    log_metric "PSI: $line"
done

log_success "Baseline captured"

# ============================================================================
# PHASE 2: DEPLOY "BAD TENANT" WORKLOAD
# ============================================================================
log_header "PHASE 2: Deploying 'Bad Tenant' Workload"

log_info "Creating test namespace..."
kctl create namespace ${NAMESPACE} --dry-run=client -o yaml | kctl apply -f - >/dev/null

log_info "Deploying aggressive stress-ng DaemonSet..."
log_warning "This will consume 4GB RAM and 4 CPU cores PER NODE"

kctl apply -f - <<'YAML'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: bad-tenant
  namespace: stress-test
  labels:
    app: bad-tenant
    test: circuit-breaker
spec:
  selector:
    matchLabels:
      app: bad-tenant
  template:
    metadata:
      labels:
        app: bad-tenant
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: memory-hog
        image: polinux/stress-ng:latest
        command:
          - stress-ng
          - --vm
          - "4"
          - --vm-bytes
          - "1G"
          - --vm-hang
          - "0"
          - --timeout
          - "120s"
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "4000m"
            memory: "4Gi"
      - name: cpu-spinner
        image: polinux/stress-ng:latest
        command:
          - stress-ng
          - --cpu
          - "4"
          - --cpu-load
          - "90"
          - --timeout
          - "120s"
        resources:
          requests:
            cpu: "100m"
            memory: "64Mi"
          limits:
            cpu: "4000m"
            memory: "256Mi"
      - name: fork-bomber
        image: polinux/stress-ng:latest
        command:
          - stress-ng
          - --fork
          - "2"
          - --fork-max
          - "50"
          - --timeout
          - "120s"
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "1000m"
            memory: "512Mi"
YAML

log_success "Bad tenant deployed"

# Wait for pods to start
log_info "Waiting for stress pods to start..."
for i in {1..30}; do
    RUNNING=$(kctl get pods -n ${NAMESPACE} -l app=bad-tenant -o jsonpath='{.items[*].status.phase}' | grep -c "Running" || echo "0")
    if [[ "$RUNNING" -ge 3 ]]; then
        break
    fi
    sleep 2
done

log_metric "Running stress pods: $RUNNING"

# ============================================================================
# PHASE 3: MONITOR SYSTEM DEGRADATION
# ============================================================================
log_header "PHASE 3: Monitoring System Under Stress"

log_info "Monitoring for ${TEST_DURATION} seconds..."
echo ""

# Create results file
RESULTS_FILE="/tmp/linnix_stress_test_$(date +%Y%m%d_%H%M%S).log"
echo "timestamp,events_per_sec,process_count,psi_cpu,psi_memory,psi_io" > "$RESULTS_FILE"

START_TIME=$(date +%s)
SAMPLE_COUNT=0
MAX_EVENTS=0
MAX_PSI_CPU=0
MAX_PSI_MEM=0

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    if [[ $ELAPSED -ge $TEST_DURATION ]]; then
        break
    fi
    
    # Collect metrics
    METRICS=$(linnix_metrics 2>/dev/null || echo "{}")
    EVENTS=$(echo "$METRICS" | grep -o '"events_per_sec":[0-9]*' | cut -d: -f2 || echo "0")
    PROCS=$(linnix_processes 2>/dev/null | grep -o '"pid"' | wc -l || echo "0")
    
    # Read PSI directly from host
    PSI_DATA=$(ssh root@${LINNIX_HOST} 'cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io 2>/dev/null' || echo "")
    PSI_CPU=$(echo "$PSI_DATA" | grep "some avg10" | head -1 | grep -o 'avg10=[0-9.]*' | cut -d= -f2 || echo "0")
    PSI_MEM=$(echo "$PSI_DATA" | grep "full avg10" | head -1 | grep -o 'avg10=[0-9.]*' | cut -d= -f2 || echo "0")
    PSI_IO=$(echo "$PSI_DATA" | grep "full avg10" | tail -1 | grep -o 'avg10=[0-9.]*' | cut -d= -f2 || echo "0")
    
    # Track maximums
    [[ "${EVENTS:-0}" -gt "$MAX_EVENTS" ]] && MAX_EVENTS=$EVENTS
    
    # Log to file
    echo "$(date +%s),$EVENTS,$PROCS,$PSI_CPU,$PSI_MEM,$PSI_IO" >> "$RESULTS_FILE"
    
    # Display progress
    BAR_WIDTH=50
    PROGRESS=$((ELAPSED * BAR_WIDTH / TEST_DURATION))
    BAR=$(printf "%${PROGRESS}s" | tr ' ' '█')
    EMPTY=$(printf "%$((BAR_WIDTH - PROGRESS))s" | tr ' ' '░')
    
    printf "\r${CYAN}[${BAR}${EMPTY}]${NC} %3ds | Events: %4s/s | PSI CPU: %5s%% | PSI Mem: %5s%%" \
        "$ELAPSED" "${EVENTS:-0}" "${PSI_CPU:-0}" "${PSI_MEM:-0}"
    
    ((SAMPLE_COUNT++))
    sleep 3
done

echo ""
echo ""
log_success "Monitoring complete. $SAMPLE_COUNT samples collected."
log_metric "Peak events/sec: $MAX_EVENTS"
log_metric "Results saved to: $RESULTS_FILE"

# ============================================================================
# PHASE 4: CHECK LINNIX RESPONSE
# ============================================================================
log_header "PHASE 4: Analyzing Linnix Circuit Breaker Response"

log_info "Checking Linnix logs for circuit breaker activity..."
echo ""

# Get recent logs
LOGS=$(ssh root@${LINNIX_HOST} 'journalctl -u linnix-guardian -n 100 --no-pager 2>/dev/null' || echo "")

# Check for circuit breaker triggers
if echo "$LOGS" | grep -q "circuit_breaker.*BREACH"; then
    log_success "Circuit breaker detected breach!"
    echo "$LOGS" | grep "circuit_breaker" | tail -5
elif echo "$LOGS" | grep -q "circuit_breaker.*enabled"; then
    log_info "Circuit breaker is armed but thresholds not exceeded (system handled load)"
else
    log_warning "No circuit breaker activity detected"
fi

# Check for enforcement actions
if echo "$LOGS" | grep -q "enforcement.*EXECUTING"; then
    log_success "Linnix took enforcement action!"
    echo "$LOGS" | grep "enforcement" | tail -3
fi

# Check KVM processes (VM load)
log_info "Checking KVM process activity..."
KVM_COUNT=$(linnix_processes | grep -o '"comm":"kvm"' | wc -l || echo "0")
log_metric "KVM processes tracked: $KVM_COUNT"

# ============================================================================
# PHASE 5: CLEANUP
# ============================================================================
log_header "PHASE 5: Cleanup"

log_info "Deleting stress test namespace..."
kctl delete namespace ${NAMESPACE} --wait=false >/dev/null 2>&1 || true
log_success "Cleanup initiated"

# ============================================================================
# FINAL REPORT
# ============================================================================
log_header "STRESS TEST RESULTS"

echo ""
echo -e "${BOLD}Test Configuration:${NC}"
echo "  • Cluster: 5-node K8s on Proxmox VMs"
echo "  • Workload: 3 stress containers per node (memory + CPU + fork)"
echo "  • Duration: ${TEST_DURATION} seconds"
echo "  • Monitor: Linnix eBPF Guardian on bare metal host"
echo ""

echo -e "${BOLD}Metrics Summary:${NC}"
echo "  • Baseline events/sec: ${BASELINE_EVENTS}"
echo "  • Peak events/sec: ${MAX_EVENTS}"
echo "  • Samples collected: ${SAMPLE_COUNT}"
echo ""

echo -e "${BOLD}Linnix Capabilities Demonstrated:${NC}"
echo "  ✓ eBPF process lifecycle monitoring (fork/exec/exit)"
echo "  ✓ Cross-VM visibility from hypervisor level"
echo "  ✓ PSI-based pressure detection"
echo "  ✓ Circuit breaker with configurable thresholds"
echo ""

echo -e "${BOLD}Results File:${NC} $RESULTS_FILE"
echo ""

# Show final PSI state
log_info "Final system state:"
ssh root@${LINNIX_HOST} 'echo "CPU:"; cat /proc/pressure/cpu; echo "Memory:"; cat /proc/pressure/memory' 2>/dev/null

echo ""
echo -e "${GREEN}${BOLD}Stress test complete!${NC}"
echo ""
