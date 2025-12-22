#!/bin/bash
# Akash Provider - Check Earnings and Lease History
# Usage: ./akash-earnings.sh

SERVER="root@178.63.224.202"
PROVIDER="akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf"

ssh $SERVER "
echo '╔════════════════════════════════════════════════════════════════════╗'
echo '║             EARNINGS REPORT - '\$(date '+%Y-%m-%d %H:%M UTC')'                  ║'
echo '╚════════════════════════════════════════════════════════════════════╝'

echo -e '\n💰 CURRENT WALLET BALANCE'
BAL=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query bank balances $PROVIDER \\
  --node http://akash-node-1:26657 -o json 2>/dev/null | jq -r '.balances[0].amount // 0')
echo \"   \$(echo \"scale=4; \$BAL / 1000000\" | awk '{printf \"%.4f\", \$1}') AKT\"

echo -e '\n📊 ACTIVE LEASES (currently earning)'
ACTIVE=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query market lease list --provider $PROVIDER \\
  --state active --node http://akash-node-1:26657 -o json 2>/dev/null)

ACTIVE_COUNT=\$(echo \"\$ACTIVE\" | jq '.leases | length')
echo \"   Active leases: \$ACTIVE_COUNT\"

if [ \"\$ACTIVE_COUNT\" -gt 0 ]; then
  echo ''
  echo '   Details:'
  echo \"\$ACTIVE\" | jq -r '.leases[] | \"   - DSEQ \(.lease.id.dseq): \(.lease.price.amount) \(.lease.price.denom)/block\"'
  
  # Calculate daily earnings
  DAILY=\$(echo \"\$ACTIVE\" | jq '[.leases[].lease.price.amount | tonumber] | add * 14400 / 1000000')
  echo ''
  echo \"   Estimated daily earnings: \$DAILY AKT\"
fi

echo -e '\n📜 LEASE HISTORY (all states)'
ALL_LEASES=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query market lease list --provider $PROVIDER \\
  --node http://akash-node-1:26657 -o json 2>/dev/null)

echo \"\$ALL_LEASES\" | jq -r '
  .leases | group_by(.lease.state) | 
  map({state: .[0].lease.state, count: length}) | 
  .[] | \"   \(.state): \(.count)\"
'

TOTAL=\$(echo \"\$ALL_LEASES\" | jq '.leases | length')
echo \"   ─────────────\"
echo \"   Total: \$TOTAL\"

echo -e '\n💸 ESCROW STATUS'
BIDS=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query market bid list --provider $PROVIDER \\
  --state open --node http://akash-node-1:26657 -o json 2>/dev/null | jq '.bids | length')
echo \"   Open bids: \$BIDS (locked: \$(echo \"\$BIDS * 0.5\" | awk '{print \$1}') AKT)\"
"
