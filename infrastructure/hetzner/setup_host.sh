#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Linnix Hetzner Host Setup Script
# ══════════════════════════════════════════════════════════════════════════════
# This script configures a fresh Hetzner Dedicated Server (Debian 12 Bookworm)
# to run Proxmox VE with a 5-node virtual cluster for Akash Network providers.
#
# Architecture:
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │  Hetzner Dedicated Server (Debian 12 + Proxmox VE)                      │
#   │  ┌─────────────────────────────────────────────────────────────────────┐│
#   │  │ eth0 (Main IP: MAIN_IP)                                             ││
#   │  │   └─▶ Internet Gateway (Hetzner's router)                           ││
#   │  └─────────────────────────────────────────────────────────────────────┘│
#   │  ┌─────────────────────────────────────────────────────────────────────┐│
#   │  │ vmbr0 (GATEWAY_IP - First usable IP from /29)                       ││
#   │  │   ├─▶ VM1 (Akash Node 1) - SUBNET_IP+1                              ││
#   │  │   ├─▶ VM2 (Akash Node 2) - SUBNET_IP+2                              ││
#   │  │   ├─▶ VM3 (Akash Node 3) - SUBNET_IP+3                              ││
#   │  │   ├─▶ VM4 (Akash Node 4) - SUBNET_IP+4                              ││
#   │  │   └─▶ VM5 (Akash Node 5) - SUBNET_IP+5                              ││
#   │  └─────────────────────────────────────────────────────────────────────┘│
#   │  ┌─────────────────────────────────────────────────────────────────────┐│
#   │  │ Linnix Guardian (eBPF) - Monitors all VMs for resource abuse        ││
#   │  └─────────────────────────────────────────────────────────────────────┘│
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Usage:
#   1. Edit the CONFIGURATION section below with your Hetzner details
#   2. Run: sudo ./setup_host.sh
#   3. Reboot when prompted
#
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION - EDIT THESE VALUES
# ══════════════════════════════════════════════════════════════════════════════

# Your Hetzner Main IP (the primary IP assigned to your server)
MAIN_IP="88.99.251.45"

# The /29 subnet you purchased (e.g., "1.2.3.0/29")
# A /29 gives you 8 addresses: network, gateway, 5 usable, broadcast
SUBNET_CIDR="178.63.224.200/29"

# Gateway IP for vmbr0 - First usable IP from your /29 subnet
# This IP will be used by the host as the gateway for VMs
GATEWAY_IP="178.63.224.201"

# Hetzner's default gateway (usually your MAIN_IP with last octet as .1)
# Example: If MAIN_IP is 1.2.3.4, this is typically 1.2.3.1
HETZNER_GATEWAY="88.99.251.1"

# Physical interface name (check with `ip link show`)
# Common: eth0, enp0s31f6, eno1, etc.
PHYSICAL_IFACE="eno1"

# ══════════════════════════════════════════════════════════════════════════════
# VALIDATION
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$MAIN_IP" == "YOUR_MAIN_IP_HERE" ]]; then
    echo "❌ ERROR: Please edit this script and set your MAIN_IP"
    exit 1
fi

if [[ "$SUBNET_CIDR" == "YOUR_SUBNET_CIDR_HERE" ]]; then
    echo "❌ ERROR: Please edit this script and set your SUBNET_CIDR"
    exit 1
fi

if [[ "$GATEWAY_IP" == "YOUR_GATEWAY_IP_HERE" ]]; then
    echo "❌ ERROR: Please edit this script and set your GATEWAY_IP"
    exit 1
fi

if [[ "$HETZNER_GATEWAY" == "YOUR_HETZNER_GATEWAY_HERE" ]]; then
    echo "❌ ERROR: Please edit this script and set your HETZNER_GATEWAY"
    exit 1
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ ERROR: This script must be run as root"
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

section() {
    echo ""
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo "  $*"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo ""
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Backed up $file"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: SYSTEM PREREQUISITES
# ══════════════════════════════════════════════════════════════════════════════

section "Step 1: Installing System Prerequisites"

log "Updating package lists..."
apt-get update

log "Installing essential packages..."
apt-get install -y \
    curl \
    wget \
    gnupg2 \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    bridge-utils \
    ifupdown2 \
    net-tools \
    iptables \
    zram-tools \
    linux-headers-$(uname -r) \
    bpftool

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: NETWORK CONFIGURATION (Hetzner Routed Setup)
# ══════════════════════════════════════════════════════════════════════════════

section "Step 2: Configuring Network (Hetzner Routed Setup)"

backup_file "/etc/network/interfaces"

# Extract subnet base for routing
SUBNET_BASE=$(echo "$SUBNET_CIDR" | cut -d'/' -f1)
SUBNET_MASK=$(echo "$SUBNET_CIDR" | cut -d'/' -f2)

log "Creating /etc/network/interfaces..."

cat > /etc/network/interfaces << EOF
# ══════════════════════════════════════════════════════════════════════════════
# Hetzner Routed Network Configuration for Proxmox + Akash
# Generated by Linnix setup_host.sh on $(date)
# ══════════════════════════════════════════════════════════════════════════════

# Loopback
auto lo
iface lo inet loopback

# ──────────────────────────────────────────────────────────────────────────────
# Physical Interface (WAN)
# ──────────────────────────────────────────────────────────────────────────────
auto ${PHYSICAL_IFACE}
iface ${PHYSICAL_IFACE} inet static
    address ${MAIN_IP}
    netmask 255.255.255.255
    pointopoint ${HETZNER_GATEWAY}
    gateway ${HETZNER_GATEWAY}

# ──────────────────────────────────────────────────────────────────────────────
# Virtual Bridge for VMs (Routed, NOT Bridged to physical)
# ──────────────────────────────────────────────────────────────────────────────
# This bridge acts as the gateway for all VMs.
# VMs connect to vmbr0 and use GATEWAY_IP as their gateway.
# Traffic is routed (not bridged) to the internet via eth0.
auto vmbr0
iface vmbr0 inet static
    address ${GATEWAY_IP}
    netmask 255.255.255.248
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    # Route the /29 subnet to this bridge
    up ip route add ${SUBNET_CIDR} dev vmbr0 || true
    # Enable proxy ARP so Hetzner's router can reach the VMs
    up echo 1 > /proc/sys/net/ipv4/conf/vmbr0/proxy_arp
    up echo 1 > /proc/sys/net/ipv4/conf/${PHYSICAL_IFACE}/proxy_arp

# ──────────────────────────────────────────────────────────────────────────────
# Source additional interface configurations
# ──────────────────────────────────────────────────────────────────────────────
source /etc/network/interfaces.d/*
EOF

log "Network configuration written to /etc/network/interfaces"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: IP FORWARDING AND SYSCTL TUNING
# ══════════════════════════════════════════════════════════════════════════════

section "Step 3: Configuring IP Forwarding and System Tuning"

backup_file "/etc/sysctl.conf"

cat > /etc/sysctl.d/99-linnix-akash.conf << 'EOF'
# ══════════════════════════════════════════════════════════════════════════════
# Linnix Akash Provider - High-Frequency Sysctl Configuration
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# IP Forwarding (Required for VM routing)
# ──────────────────────────────────────────────────────────────────────────────
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# ──────────────────────────────────────────────────────────────────────────────
# Network Performance Tuning
# ──────────────────────────────────────────────────────────────────────────────
# Allow reuse of TIME_WAIT sockets for new connections
net.ipv4.tcp_tw_reuse = 1

# Increase the maximum number of open file descriptors
fs.file-max = 1000000
fs.nr_open = 1000000

# Increase socket buffer sizes
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.ipv4.tcp_rmem = 4096 65536 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Increase connection tracking limits for high-density containers
net.netfilter.nf_conntrack_max = 1000000
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# Increase the backlog for incoming connections
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# TCP keepalive for long-running Akash connections
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10

# ──────────────────────────────────────────────────────────────────────────────
# Memory Management (Aggressive ZRAM Usage)
# ──────────────────────────────────────────────────────────────────────────────
# Aggressively use ZRAM swap to maximize tenant density
vm.swappiness = 100

# Allow overcommit (Akash providers need this for dense packing)
vm.overcommit_memory = 1
vm.overcommit_ratio = 100

# Lower the threshold for writing dirty pages to disk
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# ──────────────────────────────────────────────────────────────────────────────
# Security Hardening
# ──────────────────────────────────────────────────────────────────────────────
# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Enable SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 65535

# Enable reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF

log "Applying sysctl settings..."
sysctl --system

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: ZRAM CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

section "Step 4: Configuring ZRAM (Compressed Swap)"

backup_file "/etc/default/zramswap"

# Get total RAM in KB
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')

cat > /etc/default/zramswap << EOF
# ══════════════════════════════════════════════════════════════════════════════
# ZRAM Configuration for Linnix Akash Provider
# ══════════════════════════════════════════════════════════════════════════════
# Using 100% of RAM with zstd compression for maximum tenant density.
# With ~3:1 compression ratio, this effectively triples available memory.

# Enable ZRAM
ENABLED=true

# Use 100% of RAM for ZRAM (aggressive for Akash density)
PERCENT=100

# Use zstd for best compression ratio
ALGO=zstd

# Priority (higher than disk swap)
PRIORITY=100
EOF

log "Restarting zramswap service..."
systemctl restart zramswap || true
systemctl enable zramswap

# Verify ZRAM is working
if [[ -b /dev/zram0 ]]; then
    log "✅ ZRAM configured successfully"
    swapon --show
else
    log "⚠️  ZRAM device not found - may require reboot"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: FIREWALL CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

section "Step 5: Configuring Firewall (iptables)"

# Create firewall rules script
cat > /etc/network/if-pre-up.d/iptables-linnix << 'FIREWALL_EOF'
#!/bin/bash
# Linnix Akash Provider Firewall Rules

# Flush existing rules
iptables -F
iptables -t nat -F
iptables -t mangle -F

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow SSH (rate limited)
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m limit --limit 10/min --limit-burst 20 -j ACCEPT

# Allow Proxmox Web UI (port 8006)
iptables -A INPUT -p tcp --dport 8006 -j ACCEPT

# Allow Linnix API (port 3000)
iptables -A INPUT -p tcp --dport 3000 -j ACCEPT

# Allow ICMP (ping)
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# Forward traffic from VMs to internet
iptables -A FORWARD -i vmbr0 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o vmbr0 -j ACCEPT

# NAT for VMs (if using private IPs - not needed for routed /29)
# Uncomment if you're using NAT instead of routed setup:
# iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE

# Allow all traffic from vmbr0 (VM network)
iptables -A INPUT -i vmbr0 -j ACCEPT

# Akash Provider Ports (adjust as needed)
# gRPC
iptables -A INPUT -p tcp --dport 8443 -j ACCEPT
# Akash RPC
iptables -A INPUT -p tcp --dport 26656 -j ACCEPT
iptables -A INPUT -p tcp --dport 26657 -j ACCEPT

# Log dropped packets (useful for debugging)
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables-dropped: " --log-level 4
FIREWALL_EOF

chmod +x /etc/network/if-pre-up.d/iptables-linnix
log "Firewall rules installed"

# Apply firewall rules now
/etc/network/if-pre-up.d/iptables-linnix || true

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: LINNIX GUARDIAN INSTALLATION
# ══════════════════════════════════════════════════════════════════════════════

section "Step 6: Installing Linnix Guardian"

# Create Linnix directory
mkdir -p /opt/linnix
mkdir -p /etc/linnix
mkdir -p /var/log/linnix

log "Creating Linnix configuration..."

cat > /etc/linnix/linnix.toml << 'LINNIX_CONFIG_EOF'
# ══════════════════════════════════════════════════════════════════════════════
# Linnix Guardian Configuration for Akash Provider
# ══════════════════════════════════════════════════════════════════════════════

[api]
listen_addr = "0.0.0.0:3000"

[runtime]
offline = false

[telemetry]
sample_interval_ms = 1000
retention_seconds = 60

[reasoner]
enabled = true
endpoint = "http://localhost:8090/v1/chat/completions"
model = "linnix-3b-distilled"
window_seconds = 10
timeout_ms = 30000
min_eps_to_enable = 10

[prometheus]
enabled = true

[psi]
sustained_pressure_seconds = 15

[circuit_breaker]
enabled = true
cpu_usage_threshold = 95.0
cpu_psi_threshold = 50.0
memory_psi_full_threshold = 40.0
grace_period_secs = 10
mode = "enforce"
LINNIX_CONFIG_EOF

log "Creating systemd service file..."

cat > /etc/systemd/system/linnix-guardian.service << 'SYSTEMD_EOF'
[Unit]
Description=Linnix Guardian - eBPF Process Monitor for Akash Providers
Documentation=https://github.com/parth21shah/linnix
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/opt/linnix/cognitod --config /etc/linnix/linnix.toml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# ──────────────────────────────────────────────────────────────────────────────
# Security Settings
# ──────────────────────────────────────────────────────────────────────────────
# CRITICAL: These capabilities are required to load eBPF programs
AmbientCapabilities=CAP_BPF CAP_PERFMON CAP_NET_ADMIN CAP_SYS_ADMIN CAP_SYS_PTRACE
CapabilityBoundingSet=CAP_BPF CAP_PERFMON CAP_NET_ADMIN CAP_SYS_ADMIN CAP_SYS_PTRACE CAP_SYS_RESOURCE

# Lock down the service
NoNewPrivileges=false
ProtectSystem=false
ProtectHome=read-only
PrivateTmp=true

# Allow access to kernel interfaces needed for eBPF
ReadWritePaths=/sys/kernel/debug /sys/fs/bpf /var/log/linnix
ReadOnlyPaths=/sys/kernel/btf

# Limits
LimitNOFILE=1000000
LimitMEMLOCK=infinity

# Environment
Environment=RUST_LOG=info
Environment=LINNIX_CONFIG=/etc/linnix/linnix.toml

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

log "Reloading systemd..."
systemctl daemon-reload

# Create placeholder for the binary (user needs to copy the actual binary)
if [[ ! -f /opt/linnix/cognitod ]]; then
    cat > /opt/linnix/README.txt << 'README_EOF'
# Linnix Guardian Installation

To complete the installation, copy the compiled cognitod binary here:

    scp target/release/cognitod root@YOUR_SERVER:/opt/linnix/cognitod
    chmod +x /opt/linnix/cognitod

Then start the service:

    systemctl enable linnix-guardian
    systemctl start linnix-guardian

Check status:

    systemctl status linnix-guardian
    journalctl -u linnix-guardian -f
README_EOF
    log "⚠️  Linnix binary not found. See /opt/linnix/README.txt for instructions."
else
    chmod +x /opt/linnix/cognitod
    systemctl enable linnix-guardian
    log "✅ Linnix Guardian installed and enabled"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: PROXMOX INSTALLATION (Optional)
# ══════════════════════════════════════════════════════════════════════════════

section "Step 7: Proxmox VE Installation"

read -p "Install Proxmox VE? (y/N): " INSTALL_PROXMOX

if [[ "${INSTALL_PROXMOX,,}" == "y" ]]; then
    log "Adding Proxmox repository..."
    
    # Add Proxmox repository
    echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
    
    # Add Proxmox GPG key
    wget -qO- https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
    
    log "Updating packages..."
    apt-get update
    
    log "Installing Proxmox VE..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve postfix open-iscsi
    
    log "Removing conflicting packages..."
    apt-get remove -y linux-image-amd64 'linux-image-6.1*' || true
    update-grub
    
    log "✅ Proxmox VE installed"
else
    log "Skipping Proxmox installation"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8: FINAL VERIFICATION
# ══════════════════════════════════════════════════════════════════════════════

section "Step 8: Final Verification"

echo "
══════════════════════════════════════════════════════════════════════════════
  INSTALLATION SUMMARY
══════════════════════════════════════════════════════════════════════════════

Network Configuration:
  • Main IP: ${MAIN_IP}
  • Subnet: ${SUBNET_CIDR}
  • VM Gateway (vmbr0): ${GATEWAY_IP}
  • Physical Interface: ${PHYSICAL_IFACE}

System Tuning:
  • ZRAM: 100% RAM with zstd compression
  • vm.swappiness: 100 (aggressive ZRAM usage)
  • fs.file-max: 1,000,000
  • IP forwarding: Enabled

Linnix Guardian:
  • Config: /etc/linnix/linnix.toml
  • Service: linnix-guardian.service
  • Binary: /opt/linnix/cognitod (copy manually if not present)

Next Steps:
  1. REBOOT the server to apply network changes
  2. Copy the Linnix binary: scp cognitod root@server:/opt/linnix/
  3. Start Linnix: systemctl start linnix-guardian
  4. Use create_vm.sh to provision Akash VMs

══════════════════════════════════════════════════════════════════════════════
"

read -p "Reboot now? (y/N): " REBOOT_NOW
if [[ "${REBOOT_NOW,,}" == "y" ]]; then
    log "Rebooting in 5 seconds..."
    sleep 5
    reboot
fi

log "Setup complete. Please reboot when ready."
