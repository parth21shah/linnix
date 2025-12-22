#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Linnix Akash VM Creator for Proxmox
# ══════════════════════════════════════════════════════════════════════════════
# Creates Debian 12 Cloud-Init VMs configured for Akash Network providers.
#
# Usage:
#   ./create_vm.sh <vm_id> <vm_name> <vm_ip> [cpu] [ram_mb] [disk_gb]
#
# Examples:
#   ./create_vm.sh 101 akash-node-1 1.2.3.5 4 8192 100
#   ./create_vm.sh 102 akash-node-2 1.2.3.6 4 8192 100
#
# Or use the batch mode:
#   ./create_vm.sh --batch
#
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION - EDIT THESE VALUES
# ══════════════════════════════════════════════════════════════════════════════

# Gateway IP (the IP assigned to vmbr0 on the host)
GATEWAY_IP="178.63.224.201"

# Network mask for the /29 subnet
NETMASK="255.255.255.248"
CIDR_MASK="29"

# DNS servers
DNS1="1.1.1.1"
DNS2="8.8.8.8"

# Storage location in Proxmox
STORAGE="local"

# Cloud-Init image URL (Debian 12 generic cloud image)
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
CLOUD_IMAGE_NAME="debian-12-genericcloud-amd64.qcow2"
CLOUD_IMAGE_PATH="/var/lib/vz/template/iso/${CLOUD_IMAGE_NAME}"

# SSH public key for cloud-init (will be added to the VM)
# Replace with your actual public key
SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4PDHDtivxK3QNa1eFgLZgoSPpkuzEjEfNGGbYwTT2u parth21.shah@gmail.com"

# Default VM specs
DEFAULT_CPU=4
DEFAULT_RAM=8192  # MB
DEFAULT_DISK=100  # GB

# Batch mode: Define your 5 nodes here
# Format: VM_ID:VM_NAME:VM_IP:CPU:RAM_MB:DISK_GB
BATCH_VMS=(
    "101:akash-node-1:178.63.224.202:4:8192:100"
    "102:akash-node-2:178.63.224.203:4:8192:100"
    "103:akash-node-3:178.63.224.204:4:8192:100"
    "104:akash-node-4:178.63.224.205:4:8192:100"
    "105:akash-node-5:178.63.224.206:4:8192:100"
)

# ══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

check_proxmox() {
    if ! command -v qm &> /dev/null; then
        error "Proxmox VE not found. Please install Proxmox first."
    fi
}

download_cloud_image() {
    if [[ -f "$CLOUD_IMAGE_PATH" ]]; then
        log "Cloud image already exists: $CLOUD_IMAGE_PATH"
        return
    fi
    
    log "Downloading Debian 12 Cloud Image..."
    mkdir -p "$(dirname "$CLOUD_IMAGE_PATH")"
    wget -O "$CLOUD_IMAGE_PATH" "$CLOUD_IMAGE_URL"
    log "Downloaded to $CLOUD_IMAGE_PATH"
}

# ══════════════════════════════════════════════════════════════════════════════
# VM CREATION FUNCTION
# ══════════════════════════════════════════════════════════════════════════════

create_vm() {
    local VM_ID="$1"
    local VM_NAME="$2"
    local VM_IP="$3"
    local CPU="${4:-$DEFAULT_CPU}"
    local RAM="${5:-$DEFAULT_RAM}"
    local DISK="${6:-$DEFAULT_DISK}"
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Creating VM: $VM_NAME (ID: $VM_ID)"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "  IP: $VM_IP/$CIDR_MASK"
    log "  Gateway: $GATEWAY_IP"
    log "  CPU: $CPU cores"
    log "  RAM: $RAM MB"
    log "  Disk: $DISK GB"
    log ""
    
    # Check if VM already exists
    if qm status "$VM_ID" &> /dev/null; then
        log "⚠️  VM $VM_ID already exists. Skipping..."
        return 1
    fi
    
    # Create the VM
    log "Creating VM..."
    qm create "$VM_ID" \
        --name "$VM_NAME" \
        --memory "$RAM" \
        --cores "$CPU" \
        --cpu host \
        --net0 virtio,bridge=vmbr0 \
        --scsihw virtio-scsi-pci \
        --ostype l26 \
        --agent enabled=1 \
        --onboot 1
    
    # Import the cloud image as a disk
    log "Importing cloud image..."
    qm importdisk "$VM_ID" "$CLOUD_IMAGE_PATH" "$STORAGE" --format qcow2
    
    # Attach the imported disk
    log "Attaching disk..."
    qm set "$VM_ID" --scsi0 "${STORAGE}:vm-${VM_ID}-disk-0"
    
    # Resize the disk
    log "Resizing disk to ${DISK}GB..."
    qm resize "$VM_ID" scsi0 "${DISK}G"
    
    # Add cloud-init drive
    log "Adding cloud-init drive..."
    qm set "$VM_ID" --ide2 "${STORAGE}:cloudinit"
    
    # Set boot order
    qm set "$VM_ID" --boot c --bootdisk scsi0
    
    # Configure cloud-init
    log "Configuring cloud-init..."
    qm set "$VM_ID" \
        --ciuser root \
        --cipassword "changeme" \
        --sshkeys /root/.ssh/authorized_keys \
        --ipconfig0 "ip=${VM_IP}/${CIDR_MASK},gw=${GATEWAY_IP}" \
        --nameserver "${DNS1}" \
        --searchdomain "local"
    
    # Enable serial console for debugging
    qm set "$VM_ID" --serial0 socket --vga serial0
    
    log "✅ VM $VM_NAME ($VM_ID) created successfully"
    log ""
    log "To start the VM:"
    log "  qm start $VM_ID"
    log ""
    log "To access the VM:"
    log "  ssh root@$VM_IP"
    log ""
    
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# POST-CREATION SETUP (runs inside the VM)
# ══════════════════════════════════════════════════════════════════════════════

generate_vm_setup_script() {
    cat << 'VM_SETUP_EOF'
#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# Akash Provider Node Setup Script
# Run this inside each VM after creation
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

echo "Updating system..."
apt-get update && apt-get upgrade -y

echo "Installing Docker..."
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "Installing Kubernetes tools..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "Configuring system for Kubernetes..."
cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "Disabling swap..."
swapoff -a
sed -i '/swap/d' /etc/fstab

echo "Setup complete! Node is ready for Akash provider installation."
echo ""
echo "Next steps:"
echo "  1. Initialize Kubernetes cluster (on first node):"
echo "     kubeadm init --pod-network-cidr=10.244.0.0/16"
echo ""
echo "  2. Join worker nodes using the token from step 1"
echo ""
echo "  3. Install Akash Provider:"
echo "     https://docs.akash.network/providers/build-a-cloud-provider"
VM_SETUP_EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

main() {
    check_root
    check_proxmox
    
    # Handle batch mode
    if [[ "${1:-}" == "--batch" ]]; then
        log "Running in batch mode..."
        download_cloud_image
        
        for vm_config in "${BATCH_VMS[@]}"; do
            IFS=':' read -r vm_id vm_name vm_ip cpu ram disk <<< "$vm_config"
            create_vm "$vm_id" "$vm_name" "$vm_ip" "$cpu" "$ram" "$disk" || true
        done
        
        log ""
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "Batch creation complete!"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log ""
        log "To start all VMs:"
        for vm_config in "${BATCH_VMS[@]}"; do
            vm_id=$(echo "$vm_config" | cut -d: -f1)
            echo "  qm start $vm_id"
        done
        log ""
        log "VM setup script generated: /opt/linnix/vm_setup.sh"
        log "Copy it to each VM and run it to install Docker/K8s/Akash"
        
        # Generate the VM setup script
        mkdir -p /opt/linnix
        generate_vm_setup_script > /opt/linnix/vm_setup.sh
        chmod +x /opt/linnix/vm_setup.sh
        
        return
    fi
    
    # Handle help
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        cat << HELP_EOF
Linnix Akash VM Creator for Proxmox

Usage:
  $0 <vm_id> <vm_name> <vm_ip> [cpu] [ram_mb] [disk_gb]
  $0 --batch

Arguments:
  vm_id     Proxmox VM ID (e.g., 101)
  vm_name   VM name (e.g., akash-node-1)
  vm_ip     Static IP from your /29 subnet
  cpu       Number of CPU cores (default: $DEFAULT_CPU)
  ram_mb    RAM in MB (default: $DEFAULT_RAM)
  disk_gb   Disk size in GB (default: $DEFAULT_DISK)

Options:
  --batch   Create all 5 VMs defined in BATCH_VMS array
  --help    Show this help message

Examples:
  $0 101 akash-node-1 1.2.3.5
  $0 102 akash-node-2 1.2.3.6 8 16384 200
  $0 --batch

Configuration:
  Edit the script and set these variables:
  - GATEWAY_IP: Your vmbr0 gateway IP
  - SSH_PUBKEY: Your SSH public key
  - BATCH_VMS: Array of VM configurations for batch mode

HELP_EOF
        exit 0
    fi
    
    # Handle single VM creation
    if [[ $# -lt 3 ]]; then
        error "Usage: $0 <vm_id> <vm_name> <vm_ip> [cpu] [ram_mb] [disk_gb]"
    fi
    
    download_cloud_image
    create_vm "$@"
}

main "$@"
