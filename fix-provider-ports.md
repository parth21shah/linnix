# Fix Akash Provider Port Accessibility

## Problem
Provider reports ports 80, 443, 8443, 8444 as closed because they need to be accessible from the internet on the provider's public IP.

## Current Status
✅ Port 80: Accessible (ingress controller)
✅ Port 443: Accessible (ingress controller)  
✅ Port 8443: Accessible via NodePort 31443
✅ Port 8444: Accessible via NodePort 31444

## Root Cause
- Ports 8443/8444 cannot use hostPort (conflict with ingress controller using port 8443 internally)
- Provider is accessible via NodePort but **the blockchain registration needs to be updated** to advertise these ports correctly

## Solution: Update Provider On-Chain Registration

The provider needs to advertise its public API endpoints correctly. Currently registered as:
- `host_uri`: Not set or using incorrect port

Should be registered as:
- `host_uri`: `https://178.63.224.202:31443` (NodePort for 8443)

### Step 1: Check Current Provider Info

```bash
ssh root@178.63.224.202 'kubectl exec -it akash-provider-0 -n akash-services -- provider-services query provider get akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf --node http://akash-node-1:26657'
```

### Step 2: Update Provider Attributes

Create provider update configuration:

```bash
cat > /tmp/provider-update.yaml <<'EOF'
host: hetzner
host_uri: https://178.63.224.202:31443
email: parth21.shah+linnix@gmail.com
website: https://github.com/linnix-os/linnix
EOF
```

### Step 3: Execute Update Transaction

```bash
ssh root@178.63.224.202 'kubectl exec -it akash-provider-0 -n akash-services -- sh -c "
cat > /tmp/provider-update.yaml <<'"'"'INNEREOF'"'"'
host: hetzner
host_uri: https://178.63.224.202:31443
email: parth21.shah+linnix@gmail.com
website: https://github.com/linnix-os/linnix
INNEREOF

provider-services tx provider update /tmp/provider-update.yaml \
  --from \$AKASH_FROM \
  --node http://akash-node-1:26657 \
  --chain-id akashnet-2 \
  --gas auto \
  --gas-adjustment 1.3 \
  --gas-prices 0.025uakt \
  --yes
"'
```

### Step 4: Verify Update

```bash
# Check provider info
ssh root@178.63.224.202 'kubectl exec -it akash-provider-0 -n akash-services -- provider-services query provider get akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf --node http://akash-node-1:26657' | grep -E "host_uri|email|website"

# Test accessibility
curl -sk https://178.63.224.202:31443/status | jq -r '.address'
curl -sk https://178.63.224.202:31444 2>&1 | head -1  # Should show gRPC error (expected)
```

## Alternative Solution: Use LoadBalancer Service

If you want ports accessible on standard 8443/8444 without NodePort:

```bash
ssh root@178.63.224.202 'kubectl patch svc akash-provider-external -n akash-services -p '"'"'{"spec":{"type":"LoadBalancer","externalIPs":["178.63.224.202"]}}'"'"
```

Then update provider to use standard ports:
```
host_uri: https://178.63.224.202:8443
```

## Verification Commands

```bash
# Check all required ports are accessible
for port in 80 443 31443 31444; do
  timeout 2 bash -c "echo >/dev/tcp/178.63.224.202/$port" 2>/dev/null && \
    echo "✓ Port $port: OPEN" || echo "✗ Port $port: CLOSED"
done

# Check provider status from blockchain
ssh root@178.63.224.202 'kubectl exec akash-provider-0 -n akash-services -- provider-services query provider get akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf --node http://akash-node-1:26657'
```
