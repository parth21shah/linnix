# Hetzner Proxmox Deployment for Linnix + Akash

This directory contains production-ready scripts to deploy a 5-node virtual cluster on a Hetzner dedicated server, protected by the Linnix Guardian.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     Hetzner Dedicated Server (Debian 12)                        │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                        Host Network Configuration                        │   │
│  │                                                                         │   │
│  │   eth0 ──────────▶ Main IP (Hetzner Primary)                           │   │
│  │      │                └─▶ Gateway: Hetzner Router                       │   │
│  │      │                                                                  │   │
│  │   vmbr0 ─────────▶ Gateway IP (First usable from /29)                  │   │
│  │      │                └─▶ Routed subnet for VMs                         │   │
│  │      │                                                                  │   │
│  │      ├─▶ VM1 (akash-node-1) ─── Static IP from /29                     │   │
│  │      ├─▶ VM2 (akash-node-2) ─── Static IP from /29                     │   │
│  │      ├─▶ VM3 (akash-node-3) ─── Static IP from /29                     │   │
│  │      ├─▶ VM4 (akash-node-4) ─── Static IP from /29                     │   │
│  │      └─▶ VM5 (akash-node-5) ─── Static IP from /29                     │   │
│  │                                                                         │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                         Linnix Guardian (eBPF)                          │   │
│  │                                                                         │   │
│  │   • Monitors all processes across host and VMs                         │   │
│  │   • Detects fork bombs, CPU spin, memory leaks                         │   │
│  │   • Circuit breaker: Automatically kills runaway processes             │   │
│  │   • PSI-based thrashing detection                                      │   │
│  │                                                                         │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                          System Optimization                            │   │
│  │                                                                         │   │
│  │   • ZRAM: 100% RAM with zstd compression (~3x effective memory)        │   │
│  │   • vm.swappiness=100: Aggressive ZRAM usage                           │   │
│  │   • High file descriptor limits (1M)                                   │   │
│  │   • Optimized TCP/IP stack for containers                              │   │
│  │                                                                         │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **Hetzner Dedicated Server** with Debian 12 (Bookworm) installed
2. **Additional /29 IP Subnet** purchased from Hetzner Robot
3. **SSH Access** to the server as root

## Understanding the /29 Subnet

A /29 subnet gives you 8 IP addresses:
- 1 Network address (unusable)
- 1 Gateway address (assigned to vmbr0 on host)
- 5 Usable addresses (for VMs)
- 1 Broadcast address (unusable)

Example:
```
Subnet: 1.2.3.0/29
├── 1.2.3.0   - Network (unusable)
├── 1.2.3.1   - Gateway (vmbr0)
├── 1.2.3.2   - VM1 (akash-node-1)
├── 1.2.3.3   - VM2 (akash-node-2)
├── 1.2.3.4   - VM3 (akash-node-3)
├── 1.2.3.5   - VM4 (akash-node-4)
├── 1.2.3.6   - VM5 (akash-node-5)
└── 1.2.3.7   - Broadcast (unusable)
```

## Quick Start

### Step 1: Upload Scripts to Server

```bash
# From your local machine
scp setup_host.sh create_vm.sh root@YOUR_SERVER_IP:/root/
ssh root@YOUR_SERVER_IP
```

### Step 2: Configure and Run setup_host.sh

Edit the configuration section:

```bash
nano /root/setup_host.sh
```

Fill in these values:

```bash
MAIN_IP="YOUR_MAIN_IP_HERE"          # e.g., 95.217.123.45
SUBNET_CIDR="YOUR_SUBNET_CIDR_HERE"  # e.g., 1.2.3.0/29
GATEWAY_IP="YOUR_GATEWAY_IP_HERE"    # e.g., 1.2.3.1
HETZNER_GATEWAY="YOUR_HETZNER_GATEWAY_HERE"  # Usually MAIN_IP with .1
PHYSICAL_IFACE="eth0"                # Check with: ip link show
```

Run the setup:

```bash
chmod +x /root/setup_host.sh
./setup_host.sh
```

### Step 3: Reboot

After setup completes, reboot to apply network changes:

```bash
reboot
```

### Step 4: Install Linnix Guardian Binary

After reboot, copy the compiled Linnix binary:

```bash
# From your development machine
cd linnix
cargo build --release -p cognitod
scp target/release/cognitod root@YOUR_SERVER_IP:/opt/linnix/

# On the server
ssh root@YOUR_SERVER_IP
chmod +x /opt/linnix/cognitod
systemctl enable linnix-guardian
systemctl start linnix-guardian
systemctl status linnix-guardian
```

### Step 5: Create VMs

Edit the VM creation script:

```bash
nano /root/create_vm.sh
```

Configure these values:

```bash
GATEWAY_IP="1.2.3.1"  # Same as in setup_host.sh

# For batch mode, edit BATCH_VMS array:
BATCH_VMS=(
    "101:akash-node-1:1.2.3.2:4:8192:100"
    "102:akash-node-2:1.2.3.3:4:8192:100"
    "103:akash-node-3:1.2.3.4:4:8192:100"
    "104:akash-node-4:1.2.3.5:4:8192:100"
    "105:akash-node-5:1.2.3.6:4:8192:100"
)
```

Create all 5 VMs:

```bash
chmod +x /root/create_vm.sh
./create_vm.sh --batch
```

### Step 6: Start VMs

```bash
qm start 101
qm start 102
qm start 103
qm start 104
qm start 105
```

### Step 7: Setup VMs for Akash

SSH into each VM and run the setup script:

```bash
# Copy setup script to VM
scp /opt/linnix/vm_setup.sh root@1.2.3.2:/root/

# SSH into VM
ssh root@1.2.3.2

# Run setup
chmod +x /root/vm_setup.sh
./vm_setup.sh
```

## Files Reference

### setup_host.sh

Master script that configures:
- Network interfaces (Hetzner routed setup)
- IP forwarding and sysctl tuning
- ZRAM with 100% RAM and zstd compression
- iptables firewall rules
- Linnix Guardian systemd service
- Proxmox VE installation (optional)

### create_vm.sh

VM creation utility that:
- Downloads Debian 12 cloud image
- Creates VMs with cloud-init
- Assigns static IPs from /29 subnet
- Configures network gateway
- Enables QEMU guest agent

### Generated Files

After running setup_host.sh:

| File | Purpose |
|------|---------|
| `/etc/network/interfaces` | Network configuration |
| `/etc/sysctl.d/99-linnix-akash.conf` | Kernel tuning |
| `/etc/default/zramswap` | ZRAM configuration |
| `/etc/network/if-pre-up.d/iptables-linnix` | Firewall rules |
| `/etc/linnix/linnix.toml` | Linnix Guardian config |
| `/etc/systemd/system/linnix-guardian.service` | Linnix service |
| `/opt/linnix/vm_setup.sh` | VM setup script |

## Network Configuration Deep Dive

### Hetzner Routed Setup Explained

Unlike a typical bridged setup, Hetzner uses a **routed configuration**:

1. **eth0** connects to Hetzner's router with a point-to-point link
2. **vmbr0** is a bridge with NO physical ports (it's purely virtual)
3. **Proxy ARP** makes VMs accessible from the internet
4. **IP forwarding** routes traffic between eth0 and vmbr0

```
Internet ─▶ Hetzner Router ─▶ eth0 (Main IP)
                                │
                                ├─▶ Host processes
                                │
                          IP Forwarding
                                │
                                ▼
                    vmbr0 (Gateway IP) ─▶ VM1, VM2, VM3, VM4, VM5
```

### /etc/network/interfaces Breakdown

```
# Physical interface with point-to-point link to Hetzner gateway
auto eth0
iface eth0 inet static
    address MAIN_IP
    netmask 255.255.255.255      # /32 - single host
    pointopoint HETZNER_GATEWAY  # Hetzner's router
    gateway HETZNER_GATEWAY

# Virtual bridge for VMs (NOT bridged to eth0)
auto vmbr0
iface vmbr0 inet static
    address GATEWAY_IP           # First usable IP from /29
    netmask 255.255.255.248      # /29 = 8 addresses
    bridge_ports none            # No physical ports!
    
    # Route the /29 subnet to this bridge
    up ip route add SUBNET_CIDR dev vmbr0
    
    # Proxy ARP allows Hetzner to reach VMs
    up echo 1 > /proc/sys/net/ipv4/conf/vmbr0/proxy_arp
    up echo 1 > /proc/sys/net/ipv4/conf/eth0/proxy_arp
```

## Linnix Guardian Integration

The Linnix Guardian runs on the **host** and monitors all processes, including those inside VMs (via host PID namespace).

### Key Features for Akash Providers

1. **Fork Bomb Protection**: Detects and kills fork storms from malicious tenants
2. **CPU Spin Detection**: Identifies infinite loops consuming CPU
3. **Memory Leak Protection**: Triggers before OOM kills cascade
4. **PSI-Based Circuit Breaker**: Uses Pressure Stall Information for smart killing

### Service Management

```bash
# Check status
systemctl status linnix-guardian

# View logs
journalctl -u linnix-guardian -f

# Restart after config changes
systemctl restart linnix-guardian

# Check eBPF probe attachment
bpftool prog list | grep linnix
```

### API Access

```bash
# Health check
curl http://localhost:3000/health

# Process list
curl http://localhost:3000/processes

# SSE event stream
curl http://localhost:3000/stream
```

## ZRAM Configuration

ZRAM creates compressed swap in RAM, effectively multiplying available memory:

| RAM Size | ZRAM Size | Effective Memory* |
|----------|-----------|-------------------|
| 64 GB    | 64 GB     | ~150 GB           |
| 128 GB   | 128 GB    | ~300 GB           |
| 256 GB   | 256 GB    | ~600 GB           |

*With ~3:1 compression ratio for typical workloads

### Verification

```bash
# Check ZRAM status
swapon --show

# Check compression stats
cat /sys/block/zram0/mm_stat

# Memory usage
free -h
```

## Firewall Rules

The setup configures these iptables rules:

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH (rate limited) |
| 8006 | TCP | Proxmox Web UI |
| 3000 | TCP | Linnix API |
| 8443 | TCP | Akash gRPC |
| 26656-26657 | TCP | Akash RPC |

### Customization

Edit `/etc/network/if-pre-up.d/iptables-linnix` and reboot or run:

```bash
/etc/network/if-pre-up.d/iptables-linnix
```

## Troubleshooting

### Network Issues After Reboot

```bash
# Check interface status
ip addr show

# Check routes
ip route show

# Check bridge
brctl show vmbr0

# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward  # Should be 1

# Test connectivity from VM
ping -c 3 google.com
```

### VMs Can't Reach Internet

1. Check proxy ARP:
   ```bash
   cat /proc/sys/net/ipv4/conf/eth0/proxy_arp   # Should be 1
   cat /proc/sys/net/ipv4/conf/vmbr0/proxy_arp  # Should be 1
   ```

2. Check forwarding rules:
   ```bash
   iptables -L FORWARD -n -v
   ```

3. Check routes on host:
   ```bash
   ip route show | grep vmbr0
   ```

### Linnix Guardian Won't Start

```bash
# Check service status
systemctl status linnix-guardian

# Check logs
journalctl -u linnix-guardian -n 50

# Verify binary exists
ls -la /opt/linnix/cognitod

# Check capabilities
getcap /opt/linnix/cognitod

# Verify eBPF support
bpftool feature
```

### ZRAM Not Working

```bash
# Check module
lsmod | grep zram

# Load module manually
modprobe zram

# Check device
ls -la /dev/zram*

# Restart service
systemctl restart zramswap
```

## Security Recommendations

1. **Change SSH Port**: Edit `/etc/ssh/sshd_config` and update firewall
2. **Use SSH Keys Only**: Disable password authentication
3. **Enable Fail2Ban**: Protect against brute force
4. **Regular Updates**: Keep system and Proxmox updated
5. **Backup**: Regular backups of VM configurations

## Akash Provider Next Steps

After VMs are running:

1. **Initialize Kubernetes Cluster**:
   ```bash
   # On first node (master)
   kubeadm init --pod-network-cidr=10.244.0.0/16
   
   # Install CNI (Flannel)
   kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
   ```

2. **Join Worker Nodes**:
   ```bash
   # Use the join command from kubeadm init output
   kubeadm join MASTER_IP:6443 --token XXX --discovery-token-ca-cert-hash sha256:XXX
   ```

3. **Install Akash Provider**:
   ```bash
   # Follow Akash documentation
   # https://docs.akash.network/providers/build-a-cloud-provider
   ```

## Support

- **Linnix Issues**: https://github.com/parth21shah/linnix/issues
- **Akash Documentation**: https://docs.akash.network
- **Hetzner Documentation**: https://docs.hetzner.com

## License

AGPL-3.0 (see LICENSE in repository root)
