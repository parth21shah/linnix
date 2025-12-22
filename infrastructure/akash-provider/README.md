# Akash Provider Deployment (Linnix Protected)

This directory contains the deployment artifacts for running an Akash Provider with **aggressive overcommitment**, protected by Linnix eBPF Guardian.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Hetzner Bare Metal Server                       │
│                     (Proxmox VE + Linnix Guardian)                  │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    LINNIX GUARDIAN (eBPF)                     │  │
│  │   PSI < 80%: FREEZE (warning shot)                           │  │
│  │   PSI ≥ 80%: KILL immediately (panic level)                  │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│              ┌───────────────┼───────────────┐                      │
│              ▼               ▼               ▼                      │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐       │
│  │   K8s Node 1    │ │   K8s Node 2    │ │   K8s Node 3    │ ...   │
│  │                 │ │                 │ │                 │       │
│  │  Akash Provider │ │  Tenant Pods    │ │  Tenant Pods    │       │
│  │  Ingress (80)   │ │  Ingress (80)   │ │  Ingress (80)   │       │
│  └─────────────────┘ └─────────────────┘ └─────────────────┘       │
└─────────────────────────────────────────────────────────────────────┘
```

## Overcommitment Strategy

| Resource | Physical | Advertised | Multiplier | Protection |
|----------|----------|------------|------------|------------|
| CPU | 60 cores | 150 vCPUs | **2.5x** | Linnix PSI monitoring |
| Memory | 160 GB | 240 GB | **1.5x** | Linnix + ZRAM |
| Storage | 2 TB | 4 TB | **2.0x** | Thin provisioning |

## Files

| File | Purpose |
|------|---------|
| `values.yaml` | Helm values with overcommitment and pricing |
| `import_wallet.sh` | Securely imports your Akash wallet mnemonic |
| `install_provider.sh` | Deploys the provider via Helm |
| `check_status.sh` | Verifies provider health |

## Quick Start

### 1. Import Your Wallet

```bash
chmod +x *.sh
./import_wallet.sh
```

This will:
- Prompt for your 24-word mnemonic (hidden input)
- Create Kubernetes secret `akash-provider-key`
- Display your Akash address (akash1...)

### 2. Fund Your Wallet

Send at least **5 AKT** to your provider address for the deposit.

Check balance:
```bash
akash query bank balances <your-address> --node https://rpc.akashnet.net:443
```

### 3. Update values.yaml

Edit `values.yaml` and set:
- `from:` - Your Akash address
- `domain:` - Your provider domain

### 4. Deploy the Provider

```bash
./install_provider.sh
```

### 5. Verify Deployment

```bash
./check_status.sh
```

## Configuration Details

### Pricing (values.yaml)

```yaml
bidpricescript: |
  data["cpu"]="0.0025"      # Per millicpu per block
  data["memory"]="0.001"    # Per byte per block
  data["storage"]="0.0005"  # Per byte per block
```

### Ingress (hostNetwork Mode)

The ingress controller runs in `hostNetwork: true` mode, binding directly to port 80/443 on each node's public IP. No cloud LoadBalancer required.

```yaml
ingress:
  controller:
    hostNetwork: true
    kind: DaemonSet
```

### Linnix Protection Thresholds

On the Proxmox host (`/opt/linnix/linnix.akash.toml`):

```toml
[circuit_breaker]
cpu_psi_threshold = 35.0      # Warning level (freeze)
psi_panic_threshold = 80.0    # Panic level (kill)
freeze_duration_secs = 10     # Max freeze time
```

## Monitoring

### Provider Logs
```bash
kubectl logs -n akash-services -l app.kubernetes.io/name=provider -f
```

### Linnix Guardian
```bash
ssh root@<proxmox-host> 'journalctl -u linnix-guardian -f | grep circuit'
```

### Active Leases
```bash
kubectl exec -n akash-services $(kubectl get pods -n akash-services -l app.kubernetes.io/name=provider -o jsonpath='{.items[0].metadata.name}') -- akash query market lease list
```

## Troubleshooting

### Provider Not Registering

1. Check wallet balance (need 5+ AKT)
2. Verify mnemonic was imported correctly
3. Check logs: `kubectl logs -n akash-services -l app.kubernetes.io/name=provider`

### Ingress Not Working

1. Verify hostNetwork mode: `kubectl get pods -n ingress-nginx -o yaml | grep hostNetwork`
2. Check firewall allows port 80/443
3. Test: `curl http://<node-ip>/`

### Tenants Being Killed

This is Linnix protecting your system:
1. Check incident logs: `journalctl -u linnix-guardian | grep PANIC_KILLED`
2. If too aggressive, raise `cpu_psi_threshold` in Linnix config
3. Consider reducing overcommitment ratios

## Revenue Projection

| Metric | Value |
|--------|-------|
| Hardware Cost | €100/month |
| Effective Capacity (2.5x) | 150 vCPUs, 240GB RAM |
| Average Utilization | 60% |
| Estimated Revenue | **$300-500/month** |
| Net Profit | **$200-400/month** |

*Revenue depends on market conditions and bid pricing.*
