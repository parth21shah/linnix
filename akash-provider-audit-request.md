# Akash Provider Audit Request

## Provider Information

| Field | Value |
|-------|-------|
| **Provider Address** | `akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf` |
| **Provider URI** | `https://provider.178.63.224.202.nip.io:8443` |
| **Organization** | Linnix (eBPF-Protected Provider) |
| **Contact Email** | admin@linnix.io |
| **Region** | EU Central (Hetzner, Germany) |

## Cluster Specifications

| Node | vCPUs | Memory | Storage | OS |
|------|-------|--------|---------|-----|
| akash-node-1 | 4 | 8 GB | 100 GB | Debian 12 |
| akash-node-2 | 4 | 8 GB | 100 GB | Debian 12 |
| akash-node-3 | 4 | 8 GB | 100 GB | Debian 12 |
| akash-node-4 | 4 | 8 GB | 100 GB | Debian 12 |
| akash-node-5 | 4 | 8 GB | 100 GB | Debian 12 |

**Total Resources:**
- **CPU**: 20 vCPUs
- **Memory**: 40 GB
- **Storage**: 500 GB

## Provider Attributes

```yaml
attributes:
  - key: region
    value: eu-central
  - key: host
    value: hetzner
  - key: organization
    value: linnix-protected
```

## Unique Value Proposition

This provider features **Linnix eBPF-based kernel protection**:
- Real-time process monitoring via eBPF tracepoints
- Fork storm detection and prevention
- CPU runaway process detection
- Memory pressure monitoring
- Automated incident response

## Verification Steps

1. **Provider Status API:**
   ```bash
   curl -sk https://178.63.224.202:31443/status
   ```

2. **On-Chain Registration:**
   ```bash
   provider-services query provider get akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf --node https://akash-rpc.publicnode.com:443
   ```

3. **Certificate Validation:**
   Provider certificate is published on-chain with serial: `1882D3C167351503`

## Requested Audit Attributes

Please audit and sign for:
- `region: eu-central`
- `host: hetzner`
- `organization: linnix-protected`

## Additional Notes

- Provider is running Akash Provider v0.10.x
- Kubernetes v1.31 cluster
- All nodes have hostNetwork ingress enabled
- Using PublicNode RPC for chain connectivity

---

**Submitted:** December 20, 2025
**GitHub Issue:** [To be created at https://github.com/akash-network/community/issues/new]
