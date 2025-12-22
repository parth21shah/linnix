#!/bin/bash
# =============================================================================
# Akash Provider Installation Script
# =============================================================================
# Deploys the Akash Provider using Helm with aggressive overcommitment
# strategy, protected by Linnix eBPF monitoring.
#
# Usage: ./install_provider.sh
#
# Prerequisites:
#   - kubectl configured to access your cluster
#   - helm v3 installed
#   - Wallet imported via import_wallet.sh
#   - At least 5 AKT deposited to provider address
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
RELEASE_NAME="akash-provider"
HELM_REPO="akash"
HELM_REPO_URL="https://akash-network.github.io/helm-charts"
VALUES_FILE="values.yaml"
TIMEOUT="600s"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          Akash Provider Installation Script                    ║${NC}"
echo -e "${BLUE}║          Protected by Linnix eBPF Guardian                     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}[1/7] Checking prerequisites...${NC}"
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}ERROR: kubectl not found${NC}"
        exit 1
    fi
    echo -e "${GREEN}  ✓ kubectl available${NC}"
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}ERROR: helm not found${NC}"
        exit 1
    fi
    echo -e "${GREEN}  ✓ helm available${NC}"
    
    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}ERROR: Cannot connect to Kubernetes cluster${NC}"
        exit 1
    fi
    echo -e "${GREEN}  ✓ Cluster connection OK${NC}"
    
    # Check values.yaml exists
    if [[ ! -f "$VALUES_FILE" ]]; then
        echo -e "${RED}ERROR: ${VALUES_FILE} not found${NC}"
        echo "       Run this script from the akash-provider directory"
        exit 1
    fi
    echo -e "${GREEN}  ✓ ${VALUES_FILE} found${NC}"
}

# Create namespace
ensure_namespace() {
    echo -e "${YELLOW}[2/7] Ensuring namespace exists...${NC}"
    
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        kubectl create namespace "$NAMESPACE"
        echo -e "${GREEN}  ✓ Created namespace: ${NAMESPACE}${NC}"
    else
        echo -e "${GREEN}  ✓ Namespace exists: ${NAMESPACE}${NC}"
    fi
}

# Check wallet secret
check_wallet() {
    echo -e "${YELLOW}[3/7] Checking wallet secret...${NC}"
    
    if ! kubectl get secret akash-provider-key -n "$NAMESPACE" &> /dev/null; then
        echo -e "${RED}ERROR: Wallet secret 'akash-provider-key' not found${NC}"
        echo ""
        echo "Please run ./import_wallet.sh first to import your wallet."
        exit 1
    fi
    echo -e "${GREEN}  ✓ Wallet secret found${NC}"
}

# Add Helm repository
add_helm_repo() {
    echo -e "${YELLOW}[4/7] Adding Akash Helm repository...${NC}"
    
    # Add repo (ignore if already exists)
    helm repo add "$HELM_REPO" "$HELM_REPO_URL" 2>/dev/null || true
    
    # Update repos
    helm repo update "$HELM_REPO"
    
    echo -e "${GREEN}  ✓ Helm repository ready${NC}"
}

# Install Ingress Controller first (if hostNetwork mode)
install_ingress() {
    echo -e "${YELLOW}[5/7] Installing Ingress Controller (hostNetwork mode)...${NC}"
    
    # Check if ingress-nginx is already installed
    if helm status ingress-nginx -n ingress-nginx &> /dev/null; then
        echo -e "${GREEN}  ✓ Ingress Controller already installed${NC}"
        return
    fi
    
    # Create ingress-nginx namespace
    kubectl create namespace ingress-nginx 2>/dev/null || true
    
    # Install nginx-ingress with hostNetwork enabled
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx
    
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --set controller.hostNetwork=true \
        --set controller.hostPort.enabled=true \
        --set controller.kind=DaemonSet \
        --set controller.service.type=ClusterIP \
        --set controller.publishService.enabled=false \
        --set controller.metrics.enabled=true \
        --set controller.tolerations[0].operator=Exists \
        --wait \
        --timeout "$TIMEOUT"
    
    echo -e "${GREEN}  ✓ Ingress Controller installed (hostNetwork mode)${NC}"
}

# Install Akash Provider
install_provider() {
    echo -e "${YELLOW}[6/7] Installing Akash Provider...${NC}"
    
    # Show what we're about to deploy
    echo -e "${CYAN}  Configuration:${NC}"
    echo "    - CPU Overcommit: 2.5x"
    echo "    - Memory Overcommit: 1.5x"
    echo "    - Storage Overcommit: 2.0x"
    echo "    - Region: eu-central (Hetzner)"
    echo "    - Protected by: Linnix eBPF Guardian"
    echo ""
    
    # Install/upgrade the provider
    helm upgrade --install "$RELEASE_NAME" "$HELM_REPO/provider" \
        --namespace "$NAMESPACE" \
        --values "$VALUES_FILE" \
        --wait \
        --timeout "$TIMEOUT"
    
    echo -e "${GREEN}  ✓ Akash Provider installed${NC}"
}

# Wait for pods
wait_for_pods() {
    echo -e "${YELLOW}[7/7] Waiting for pods to be ready...${NC}"
    
    # Wait for provider pod
    echo -n "  Waiting for provider pod"
    RETRIES=60
    while [[ $RETRIES -gt 0 ]]; do
        STATUS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
        if [[ "$STATUS" == "Running" ]]; then
            break
        fi
        echo -n "."
        sleep 5
        RETRIES=$((RETRIES - 1))
    done
    echo ""
    
    if [[ "$STATUS" == "Running" ]]; then
        echo -e "${GREEN}  ✓ Provider pod is Running${NC}"
    else
        echo -e "${RED}  ✗ Provider pod not ready (status: ${STATUS})${NC}"
        echo ""
        echo "Check logs with: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=provider"
    fi
    
    # Show pod status
    echo ""
    echo -e "${CYAN}Pod Status:${NC}"
    kubectl get pods -n "$NAMESPACE" -o wide
}

# Print summary
print_summary() {
    # Get provider address from values
    PROVIDER_ADDRESS=$(grep -E "^from:" "$VALUES_FILE" | awk '{print $2}' | tr -d '"' || echo "unknown")
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              AKASH PROVIDER INSTALLATION COMPLETE              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Provider Details:${NC}"
    echo "  Address: ${PROVIDER_ADDRESS}"
    echo "  Region:  eu-central (Hetzner)"
    echo ""
    echo -e "${BLUE}Overcommitment Strategy (Linnix Protected):${NC}"
    echo "  CPU:     2.5x (Sell 250% of physical cores)"
    echo "  Memory:  1.5x (Sell 150% of physical RAM)"
    echo "  Storage: 2.0x (Sell 200% of physical disk)"
    echo ""
    echo -e "${BLUE}Safety Net:${NC}"
    echo "  Linnix Guardian is monitoring PSI (Pressure Stall Information)"
    echo "  - PSI 35-80%: Freeze offending process (warning shot)"
    echo "  - PSI 80%+:   Kill immediately (panic level)"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Verify provider status: ./check_status.sh"
    echo "  2. Check blockchain registration:"
    echo "     akash query provider get ${PROVIDER_ADDRESS}"
    echo "  3. Monitor incoming leases:"
    echo "     kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=provider -f"
    echo ""
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "  # View provider logs"
    echo "  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=provider -f"
    echo ""
    echo "  # Check Linnix Guardian status"
    echo "  ssh root@<proxmox-host> 'systemctl status linnix-guardian'"
    echo ""
    echo "  # View circuit breaker activity"
    echo "  ssh root@<proxmox-host> 'journalctl -u linnix-guardian | grep circuit'"
    echo ""
}

# Main execution
main() {
    check_prerequisites
    ensure_namespace
    check_wallet
    add_helm_repo
    install_ingress
    install_provider
    wait_for_pods
    print_summary
}

main
