#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Linnix Hetzner Deployment - Server B20251217-3319241-2895459
# ══════════════════════════════════════════════════════════════════════════════
# This is your PERSONALIZED deployment script for:
#   Server: 88.99.251.45
#   IPv6:   2a01:4f8:10b:8ec::2
#
# IMPORTANT: You need to purchase a /29 subnet from Hetzner Robot first!
#   Robot → IPs → Order additional subnets → /29 subnet
#
# After purchase, update SUBNET_CIDR and GATEWAY_IP below.
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: SSH INTO YOUR SERVER
# ══════════════════════════════════════════════════════════════════════════════
# 
# From your local machine:
#   ssh root@88.99.251.45
#
# The server is currently in Rescue Mode. You need to install Debian 12 first.
# ══════════════════════════════════════════════════════════════════════════════

cat << 'RESCUE_INSTRUCTIONS'
══════════════════════════════════════════════════════════════════════════════
  STEP-BY-STEP DEPLOYMENT INSTRUCTIONS
══════════════════════════════════════════════════════════════════════════════

Your Server Details:
  Main IPv4:    88.99.251.45
  Main IPv6:    2a01:4f8:10b:8ec::2
  Gateway:      88.99.251.1 (typical Hetzner gateway)
  Network:      88.99.251.0/24 (typical Hetzner network)

──────────────────────────────────────────────────────────────────────────────
PHASE 1: INSTALL DEBIAN 12 (Currently in Rescue Mode)
──────────────────────────────────────────────────────────────────────────────

1. SSH into the server:
   ssh root@88.99.251.45

2. Run Hetzner's installimage:
   installimage

3. Choose:
   - Debian 12 (Bookworm)
   - Accept defaults
   - Save and confirm

4. Reboot:
   reboot

5. Wait 2-3 minutes for Debian to boot

6. SSH back in:
   ssh root@88.99.251.45

──────────────────────────────────────────────────────────────────────────────
PHASE 2: ORDER /29 SUBNET (Required for 5 VMs)
──────────────────────────────────────────────────────────────────────────────

1. Go to Hetzner Robot:
   https://robot.hetzner.com

2. Navigate to: IPs → Order additional subnets

3. Select your server: 88.99.251.45

4. Choose: /29 subnet (6 usable IPs)

5. Complete the order

6. Note your subnet! Example: 5.9.10.0/29

──────────────────────────────────────────────────────────────────────────────
PHASE 3: UPLOAD AND RUN LINNIX SETUP
──────────────────────────────────────────────────────────────────────────────

From your local machine (linnix directory):

1. Upload deployment scripts:
   scp infrastructure/hetzner/setup_host.sh root@88.99.251.45:/root/
   scp infrastructure/hetzner/create_vm.sh root@88.99.251.45:/root/

2. SSH into server:
   ssh root@88.99.251.45

3. Edit setup_host.sh with your IPs:
   nano /root/setup_host.sh

   Replace these lines:
   MAIN_IP="88.99.251.45"              # ✅ Already correct
   SUBNET_CIDR="YOUR_PURCHASED_SUBNET" # ❌ ADD YOUR /29 (e.g., "5.9.10.0/29")
   GATEWAY_IP="FIRST_USABLE_IP"        # ❌ ADD (e.g., "5.9.10.1")
   HETZNER_GATEWAY="88.99.251.1"       # ✅ Should be correct
   PHYSICAL_IFACE="eth0"               # ⚠️  Verify with: ip link show

4. Run setup:
   chmod +x /root/setup_host.sh
   ./setup_host.sh

5. When prompted, install Proxmox: y

6. Reboot when prompted: y

──────────────────────────────────────────────────────────────────────────────
PHASE 4: DEPLOY LINNIX GUARDIAN
──────────────────────────────────────────────────────────────────────────────

After reboot, from your local machine:

1. Build Linnix:
   cd ~/linnix
   cargo build --release -p cognitod

2. Copy binary to server:
   scp target/release/cognitod root@88.99.251.45:/opt/linnix/
   scp target/bpf/linnix-ai-ebpf-ebpf.o root@88.99.251.45:/opt/linnix/

3. SSH back in:
   ssh root@88.99.251.45

4. Start Linnix Guardian:
   chmod +x /opt/linnix/cognitod
   systemctl enable linnix-guardian
   systemctl start linnix-guardian

5. Verify it's running:
   systemctl status linnix-guardian
   curl http://localhost:3000/health

6. Watch logs:
   journalctl -u linnix-guardian -f

──────────────────────────────────────────────────────────────────────────────
PHASE 5: CREATE AKASH VMs
──────────────────────────────────────────────────────────────────────────────

1. Edit VM creation script:
   nano /root/create_vm.sh

   Update GATEWAY_IP to match your /29 gateway (same as in setup_host.sh)
   
   Update BATCH_VMS with your /29 IPs:
   Example if your subnet is 5.9.10.0/29:
   BATCH_VMS=(
       "101:akash-node-1:5.9.10.2:4:8192:100"
       "102:akash-node-2:5.9.10.3:4:8192:100"
       "103:akash-node-3:5.9.10.4:4:8192:100"
       "104:akash-node-4:5.9.10.5:4:8192:100"
       "105:akash-node-5:5.9.10.6:4:8192:100"
   )

2. Create all VMs:
   chmod +x /root/create_vm.sh
   ./create_vm.sh --batch

3. Start all VMs:
   qm start 101
   qm start 102
   qm start 103
   qm start 104
   qm start 105

4. Check VM status:
   qm list

5. Access Proxmox Web UI:
   https://88.99.251.45:8006
   Username: root
   Password: (your root password)

──────────────────────────────────────────────────────────────────────────────
PHASE 6: SETUP VMs FOR AKASH
──────────────────────────────────────────────────────────────────────────────

For each VM (replace 5.9.10.2 with your actual VM IPs):

1. SSH into VM:
   ssh root@5.9.10.2

2. Run setup script:
   wget http://88.99.251.45:3000/vm_setup.sh || \
   scp root@88.99.251.45:/opt/linnix/vm_setup.sh /root/
   
   chmod +x /root/vm_setup.sh
   ./vm_setup.sh

3. Repeat for all 5 VMs

──────────────────────────────────────────────────────────────────────────────
VERIFICATION CHECKLIST
──────────────────────────────────────────────────────────────────────────────

Host (88.99.251.45):
  ✓ Network configured: ip addr show
  ✓ vmbr0 bridge exists: brctl show
  ✓ IP forwarding enabled: cat /proc/sys/net/ipv4/ip_forward
  ✓ ZRAM active: swapon --show
  ✓ Linnix running: systemctl status linnix-guardian
  ✓ Proxmox accessible: https://88.99.251.45:8006

VMs:
  ✓ All 5 VMs running: qm list
  ✓ VMs have internet: ssh root@VM_IP "ping -c 3 google.com"
  ✓ Docker installed: ssh root@VM_IP "docker --version"
  ✓ Kubernetes ready: ssh root@VM_IP "kubeadm version"

──────────────────────────────────────────────────────────────────────────────
TROUBLESHOOTING
──────────────────────────────────────────────────────────────────────────────

Network not working after reboot:
  # Check interface names changed
  ip link show
  
  # Update /etc/network/interfaces if needed
  nano /etc/network/interfaces
  
  # Restart networking
  systemctl restart networking

VMs can't reach internet:
  # Check proxy ARP
  cat /proc/sys/net/ipv4/conf/eth0/proxy_arp   # Should be 1
  cat /proc/sys/net/ipv4/conf/vmbr0/proxy_arp  # Should be 1
  
  # Check forwarding
  iptables -L FORWARD -n -v

Linnix not starting:
  # Check logs
  journalctl -u linnix-guardian -xe
  
  # Verify binary exists
  ls -la /opt/linnix/cognitod
  
  # Check eBPF support
  bpftool feature

──────────────────────────────────────────────────────────────────────────────
NEXT STEPS: AKASH PROVIDER SETUP
──────────────────────────────────────────────────────────────────────────────

1. Initialize Kubernetes on first VM (master node)
2. Join other 4 VMs as worker nodes
3. Install Akash provider stack
4. Configure Linnix to monitor Akash workloads

Full Akash setup guide: https://docs.akash.network/providers/

══════════════════════════════════════════════════════════════════════════════
RESCUE_INSTRUCTIONS

# Generate subnet calculator helper
cat << 'SUBNET_CALC'

══════════════════════════════════════════════════════════════════════════════
/29 SUBNET CALCULATOR
══════════════════════════════════════════════════════════════════════════════

A /29 subnet gives you 8 addresses total:
  - 1 Network address (unusable)
  - 1 Gateway (for vmbr0 on host)
  - 5 Usable IPs (for your 5 VMs)
  - 1 Broadcast (unusable)

Example: If your purchased subnet is 5.9.10.0/29

  5.9.10.0  - Network address (unusable)
  5.9.10.1  - Gateway (assign to vmbr0) ← Use in setup_host.sh GATEWAY_IP
  5.9.10.2  - VM 1 (akash-node-1)
  5.9.10.3  - VM 2 (akash-node-2)
  5.9.10.4  - VM 3 (akash-node-3)
  5.9.10.5  - VM 4 (akash-node-4)
  5.9.10.6  - VM 5 (akash-node-5)
  5.9.10.7  - Broadcast (unusable)

──────────────────────────────────────────────────────────────────────────────
YOUR CONFIGURATION VALUES (fill in after ordering subnet):
──────────────────────────────────────────────────────────────────────────────

MAIN_IP="88.99.251.45"
SUBNET_CIDR="___________________"  # Your /29 (e.g., "5.9.10.0/29")
GATEWAY_IP="___________________"   # First usable (e.g., "5.9.10.1")
HETZNER_GATEWAY="88.99.251.1"
PHYSICAL_IFACE="eth0"  # Verify with: ip link show

VM_IPS:
  akash-node-1: ___________________  # e.g., 5.9.10.2
  akash-node-2: ___________________  # e.g., 5.9.10.3
  akash-node-3: ___________________  # e.g., 5.9.10.4
  akash-node-4: ___________________  # e.g., 5.9.10.5
  akash-node-5: ___________________  # e.g., 5.9.10.6

══════════════════════════════════════════════════════════════════════════════
SUBNET_CALC
