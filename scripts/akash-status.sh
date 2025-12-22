#!/bin/bash
# Akash Provider Status Script
# Usage: ./akash-status.sh

SERVER="root@178.63.224.202"
PROVIDER="akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf"

ssh $SERVER "
echo '╔════════════════════════════════════════════════════════════════════╗'
echo '║             AKASH PROVIDER STATUS                                  ║'
echo '║             '\$(date '+%Y-%m-%d %H:%M UTC')'                                   ║'
echo '╚════════════════════════════════════════════════════════════════════╝'

echo -e '\n📍 PROVIDER INFO'
echo '   Address: $PROVIDER'
echo '   URI: https://178.63.224.202:8443'
echo '   Domain: https://provider.178.63.224.202.nip.io'

echo -e '\n💰 WALLET BALANCE'
BAL=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query bank balances $PROVIDER \\
  --node http://akash-node-1:26657 -o json 2>/dev/null | jq -r '.balances[0].amount // 0')
echo \"   \$(echo \"scale=2; \$BAL / 1000000\" | awk '{printf \"%.2f\", \$1}') AKT\"

echo -e '\n📊 MARKETPLACE STATUS'
BIDS=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query market bid list --provider $PROVIDER \\
  --state open --node http://akash-node-1:26657 -o json 2>/dev/null | jq '.bids | length')
LEASES=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query market lease list --provider $PROVIDER \\
  --state active --node http://akash-node-1:26657 -o json 2>/dev/null | jq '.leases | length')
echo \"   Open Bids: \$BIDS\"
echo \"   Active Leases: \$LEASES\"

echo -e '\n🔧 COMPONENTS'
echo \"   Provider Pod:  \$(kubectl get pod -n akash-services akash-provider-0 --no-headers 2>/dev/null | awk '{print \$3\" (restarts: \"\$4\")\"}')\"
echo \"   RPC Node:      \$(kubectl get pod -n akash-services akash-node-1-0 --no-headers 2>/dev/null | awk '{print \$3\" (restarts: \"\$4\")\"}')\"

echo -e '\n⚙️  CONFIGURATION'
kubectl exec -n akash-services akash-provider-0 -c provider -- env 2>/dev/null | grep -E 'OVERCOMMIT|AKASH_NODE=' | sed 's/^/   /'

echo -e '\n📈 ACTIVITY (last 24h)'
echo \"   Orders detected: \$(kubectl logs -n akash-services akash-provider-0 -c provider --since=24h 2>&1 | grep -c 'order detected' || echo 0)\"
echo \"   Bids submitted: \$(kubectl logs -n akash-services akash-provider-0 -c provider --since=24h 2>&1 | grep -c 'submitting fulfillment' || echo 0)\"
echo \"   Insufficient capacity: \$(kubectl logs -n akash-services akash-provider-0 -c provider --since=24h 2>&1 | grep -c 'insufficient capacity' || echo 0)\"
"
