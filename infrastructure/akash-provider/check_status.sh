#!/bin/bash
# =============================================================================
# Akash Provider Status Check Script
# =============================================================================
# Verifies that the Akash Provider is running correctly and can communicate
# with the blockchain.
#
# Usage: ./check_status.sh
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

NAMESPACE="akash-services"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Akash Provider Status Check                       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check 1: Provider Pod Status
check_provider_pod() {
    echo -e "${YELLOW}[1/6] Checking Provider Pod Status...${NC}"
    
    POD_STATUS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ "$POD_STATUS" == "Running" ]]; then
        echo -e "${GREEN}  ✓ Provider Pod: ${POD_NAME} (${POD_STATUS})${NC}"
        
        # Check ready status
        READY=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$READY" == "True" ]]; then
            echo -e "${GREEN}  ✓ Pod Ready: Yes${NC}"
        else
            echo -e "${YELLOW}  ⚠ Pod Ready: ${READY}${NC}"
        fi
    else
        echo -e "${RED}  ✗ Provider Pod: ${POD_STATUS}${NC}"
        echo ""
        echo "  Troubleshooting:"
        echo "    kubectl describe pod -n ${NAMESPACE} -l app.kubernetes.io/name=provider"
        echo "    kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=provider"
    fi
    echo ""
}

# Check 2: Provider Health Endpoint
check_provider_health() {
    echo -e "${YELLOW}[2/6] Checking Provider Health Endpoint...${NC}"
    
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$POD_NAME" ]]; then
        # Port-forward and check health
        kubectl port-forward -n "$NAMESPACE" "pod/${POD_NAME}" 8443:8443 &>/dev/null &
        PF_PID=$!
        sleep 2
        
        HEALTH=$(curl -sk https://localhost:8443/status 2>/dev/null || echo "unreachable")
        kill $PF_PID 2>/dev/null || true
        
        if [[ "$HEALTH" != "unreachable" ]]; then
            echo -e "${GREEN}  ✓ Health endpoint responding${NC}"
        else
            echo -e "${YELLOW}  ⚠ Health endpoint not responding (may need more time)${NC}"
        fi
    else
        echo -e "${RED}  ✗ No provider pod found${NC}"
    fi
    echo ""
}

# Check 3: Blockchain Connectivity
check_blockchain() {
    echo -e "${YELLOW}[3/6] Checking Blockchain Connectivity...${NC}"
    
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$POD_NAME" ]]; then
        # Try to query the blockchain from inside the pod
        BLOCK_HEIGHT=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- akash query block --node https://rpc.akashnet.net:443 2>/dev/null | grep -o '"height":"[0-9]*"' | head -1 | grep -o '[0-9]*' || echo "")
        
        if [[ -n "$BLOCK_HEIGHT" ]]; then
            echo -e "${GREEN}  ✓ Connected to Akash blockchain${NC}"
            echo -e "${GREEN}  ✓ Current block height: ${BLOCK_HEIGHT}${NC}"
        else
            echo -e "${YELLOW}  ⚠ Could not query blockchain (provider may be syncing)${NC}"
        fi
    else
        echo -e "${RED}  ✗ No provider pod found${NC}"
    fi
    echo ""
}

# Check 4: Provider Registration
check_registration() {
    echo -e "${YELLOW}[4/6] Checking Provider Registration...${NC}"
    
    # Get provider address from the running pod
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$POD_NAME" ]]; then
        # Query provider from blockchain
        PROVIDER_INFO=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- akash query provider list --node https://rpc.akashnet.net:443 2>/dev/null | head -30 || echo "")
        
        if [[ -n "$PROVIDER_INFO" ]]; then
            echo -e "${GREEN}  ✓ Provider query successful${NC}"
            echo ""
            echo "  Provider List (first few):"
            echo "$PROVIDER_INFO" | head -10
        else
            echo -e "${YELLOW}  ⚠ Could not query provider list${NC}"
        fi
    else
        echo -e "${RED}  ✗ No provider pod found${NC}"
    fi
    echo ""
}

# Check 5: Ingress Controller
check_ingress() {
    echo -e "${YELLOW}[5/6] Checking Ingress Controller...${NC}"
    
    # Check ingress-nginx pods
    INGRESS_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
    
    if [[ -n "$INGRESS_PODS" ]]; then
        RUNNING_COUNT=$(echo "$INGRESS_PODS" | tr ' ' '\n' | grep -c "Running" || echo "0")
        echo -e "${GREEN}  ✓ Ingress Controller pods running: ${RUNNING_COUNT}${NC}"
    else
        echo -e "${YELLOW}  ⚠ No ingress-nginx pods found${NC}"
    fi
    
    # Check if listening on port 80
    echo ""
    echo "  Checking port 80 on nodes:"
    
    # Get node IPs
    NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || echo "")
    
    if [[ -z "$NODE_IPS" ]]; then
        # Try internal IPs if no external
        NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
    fi
    
    for IP in $NODE_IPS; do
        if timeout 2 bash -c "echo >/dev/tcp/${IP}/80" 2>/dev/null; then
            echo -e "${GREEN}    ✓ ${IP}:80 - OPEN${NC}"
        else
            echo -e "${YELLOW}    ⚠ ${IP}:80 - CLOSED or FILTERED${NC}"
        fi
    done
    echo ""
}

# Check 6: Linnix Guardian Status
check_linnix() {
    echo -e "${YELLOW}[6/6] Checking Linnix Guardian (Host Protection)...${NC}"
    
    # This requires SSH access to the Proxmox host
    # We'll check via the Linnix API if accessible
    
    LINNIX_API="http://88.99.251.45:3000"  # Adjust to your host
    
    LINNIX_STATUS=$(curl -s --connect-timeout 2 "${LINNIX_API}/status" 2>/dev/null || echo "")
    
    if [[ -n "$LINNIX_STATUS" ]]; then
        echo -e "${GREEN}  ✓ Linnix Guardian API responding${NC}"
        
        # Get process count
        PROCESS_COUNT=$(curl -s "${LINNIX_API}/processes" 2>/dev/null | jq '. | length' 2>/dev/null || echo "?")
        echo -e "${GREEN}  ✓ Monitoring ${PROCESS_COUNT} processes${NC}"
        
        # Check for recent circuit breaker activity
        INCIDENTS=$(curl -s "${LINNIX_API}/insights" 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")
        if [[ "$INCIDENTS" -gt 0 ]]; then
            echo -e "${YELLOW}  ⚠ ${INCIDENTS} recent incidents detected${NC}"
        else
            echo -e "${GREEN}  ✓ No recent incidents${NC}"
        fi
    else
        echo -e "${YELLOW}  ⚠ Cannot reach Linnix API at ${LINNIX_API}${NC}"
        echo "    (This is OK if Linnix is running on a different host)"
        echo ""
        echo "    To check manually:"
        echo "      ssh root@<proxmox-host> 'systemctl status linnix-guardian'"
    fi
    echo ""
}

# Summary
print_summary() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                         SUMMARY                                ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Quick status
    POD_STATUS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    
    if [[ "$POD_STATUS" == "Running" ]]; then
        echo -e "${GREEN}Provider Status: RUNNING ✓${NC}"
    else
        echo -e "${RED}Provider Status: ${POD_STATUS} ✗${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo ""
    echo "  # View provider logs"
    echo "  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=provider -f"
    echo ""
    echo "  # Check active leases"
    echo "  kubectl exec -n ${NAMESPACE} \$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].metadata.name}') -- akash query market lease list"
    echo ""
    echo "  # Check Linnix circuit breaker"
    echo "  ssh root@<host> 'journalctl -u linnix-guardian --since \"1 hour ago\" | grep circuit'"
    echo ""
}

# Main
main() {
    check_provider_pod
    check_provider_health
    check_blockchain
    check_registration
    check_ingress
    check_linnix
    print_summary
}

main
