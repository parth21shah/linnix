#!/bin/bash
# =============================================================================
# Akash Provider Wallet Import Script
# =============================================================================
# This script securely imports your Akash mnemonic (seed phrase) into
# a Kubernetes Secret for use by the Akash Provider.
#
# Usage: ./import_wallet.sh
#
# Prerequisites:
#   - kubectl configured to access your cluster
#   - akash CLI installed (for address derivation)
#
# Security Notes:
#   - Mnemonic is read securely (no echo)
#   - Never stored in plaintext on disk
#   - Stored as base64 in Kubernetes Secret
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NAMESPACE="akash-services"
SECRET_NAME="akash-provider-key"
KEY_NAME="provider"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          Akash Provider Wallet Import Script                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}ERROR: kubectl not found. Please install kubectl.${NC}"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}ERROR: Cannot connect to Kubernetes cluster.${NC}"
        echo "       Please configure kubectl to access your cluster."
        exit 1
    fi
    
    echo -e "${GREEN}✓ kubectl connected to cluster${NC}"
}

# Create namespace if it doesn't exist
ensure_namespace() {
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        echo -e "${YELLOW}Creating namespace: ${NAMESPACE}${NC}"
        kubectl create namespace "$NAMESPACE"
        echo -e "${GREEN}✓ Namespace created${NC}"
    else
        echo -e "${GREEN}✓ Namespace ${NAMESPACE} exists${NC}"
    fi
}

# Check if secret already exists
check_existing_secret() {
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        echo -e "${YELLOW}WARNING: Secret '${SECRET_NAME}' already exists in namespace '${NAMESPACE}'${NC}"
        echo ""
        read -p "Do you want to replace it? (yes/no): " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            echo -e "${RED}Aborted. Existing secret not modified.${NC}"
            exit 0
        fi
        kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
        echo -e "${GREEN}✓ Existing secret deleted${NC}"
    fi
}

# Securely read mnemonic
read_mnemonic() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}SECURITY WARNING:${NC}"
    echo "  Your mnemonic (seed phrase) will NOT be displayed as you type."
    echo "  Make sure you are in a private environment."
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Read mnemonic securely (no echo)
    echo -e "${YELLOW}Enter your Akash mnemonic (24 words, space-separated):${NC}"
    read -s MNEMONIC
    echo ""
    
    # Validate word count
    WORD_COUNT=$(echo "$MNEMONIC" | wc -w)
    if [[ "$WORD_COUNT" -ne 24 ]] && [[ "$WORD_COUNT" -ne 12 ]]; then
        echo -e "${RED}ERROR: Mnemonic must be 12 or 24 words. Got: ${WORD_COUNT} words.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Mnemonic received (${WORD_COUNT} words)${NC}"
}

# Derive Akash address from mnemonic
derive_address() {
    echo -e "${YELLOW}Deriving Akash address...${NC}"
    
    # Check if akash CLI is available
    if command -v akash &> /dev/null; then
        # Use akash CLI to derive address
        AKASH_ADDRESS=$(echo "$MNEMONIC" | akash keys add "$KEY_NAME" --recover --dry-run --output json 2>/dev/null | jq -r '.address')
        
        if [[ -z "$AKASH_ADDRESS" ]] || [[ "$AKASH_ADDRESS" == "null" ]]; then
            echo -e "${YELLOW}Could not derive address via CLI. Using fallback method...${NC}"
            derive_address_fallback
        fi
    else
        echo -e "${YELLOW}akash CLI not found. Using fallback method...${NC}"
        derive_address_fallback
    fi
    
    echo -e "${GREEN}✓ Akash Address: ${AKASH_ADDRESS}${NC}"
}

# Fallback: derive address using a temporary container
derive_address_fallback() {
    # Create a temporary pod to derive the address
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: akash-key-derive
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
  - name: akash
    image: ghcr.io/akash-network/provider:0.6.4
    command: ["sleep", "300"]
EOF
    
    echo "Waiting for temporary pod..."
    kubectl wait --for=condition=Ready pod/akash-key-derive -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1
    
    # Derive address inside the pod
    AKASH_ADDRESS=$(kubectl exec -n "$NAMESPACE" akash-key-derive -- sh -c "echo '$MNEMONIC' | akash keys add temp --recover --dry-run --output json" 2>/dev/null | jq -r '.address')
    
    # Cleanup
    kubectl delete pod akash-key-derive -n "$NAMESPACE" --grace-period=0 --force >/dev/null 2>&1 || true
    
    if [[ -z "$AKASH_ADDRESS" ]] || [[ "$AKASH_ADDRESS" == "null" ]]; then
        # Last resort: generate a placeholder
        AKASH_ADDRESS="akash1_UNABLE_TO_DERIVE_CHECK_MNEMONIC"
        echo -e "${RED}WARNING: Could not derive address. Please verify your mnemonic.${NC}"
    fi
}

# Create Kubernetes secret
create_secret() {
    echo -e "${YELLOW}Creating Kubernetes secret...${NC}"
    
    # Create secret with mnemonic
    kubectl create secret generic "$SECRET_NAME" \
        --namespace="$NAMESPACE" \
        --from-literal=mnemonic="$MNEMONIC" \
        --from-literal=key-name="$KEY_NAME"
    
    # Label the secret
    kubectl label secret "$SECRET_NAME" -n "$NAMESPACE" \
        app.kubernetes.io/name=akash-provider \
        app.kubernetes.io/component=wallet
    
    echo -e "${GREEN}✓ Secret created: ${SECRET_NAME}${NC}"
}

# Clear mnemonic from memory
cleanup() {
    MNEMONIC=""
    unset MNEMONIC
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Print summary
print_summary() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    WALLET IMPORT SUCCESSFUL                     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Akash Address:${NC}"
    echo -e "  ${YELLOW}${AKASH_ADDRESS}${NC}"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Send at least 5 AKT to this address for the provider deposit"
    echo "  2. Update 'from:' field in values.yaml with this address"
    echo "  3. Run ./install_provider.sh to deploy the provider"
    echo ""
    echo -e "${BLUE}Check your balance:${NC}"
    echo "  akash query bank balances ${AKASH_ADDRESS} --node https://rpc.akashnet.net:443"
    echo ""
    echo -e "${BLUE}Secret location:${NC}"
    echo "  Namespace: ${NAMESPACE}"
    echo "  Secret: ${SECRET_NAME}"
    echo ""
}

# Main execution
main() {
    check_prerequisites
    ensure_namespace
    check_existing_secret
    read_mnemonic
    derive_address
    create_secret
    print_summary
}

main
