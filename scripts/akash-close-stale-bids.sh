#!/bin/bash
# Akash Provider - Close Stale Bids (older than X hours)
# Usage: ./akash-close-stale-bids.sh [hours]
# Default: 20 hours

MAX_HOURS=${1:-20}
SERVER="root@178.63.224.202"
PROVIDER="akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf"

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   CLOSE STALE BIDS (older than ${MAX_HOURS} hours)                           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

ssh $SERVER "
CURRENT_HEIGHT=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query block --node http://akash-node-1:26657 2>/dev/null | grep 'height:' | head -1 | awk '{print \$2}' | tr -d '\"')

MAX_BLOCKS=\$(echo '${MAX_HOURS} * 3600 / 6' | bc)

echo \"Current block: \$CURRENT_HEIGHT\"
echo \"Max age: ${MAX_HOURS} hours (\$MAX_BLOCKS blocks)\"
echo ''

# Get all open bids
BIDS=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query market bid list --provider $PROVIDER \\
  --state open --node http://akash-node-1:26657 -o json 2>/dev/null)

# Find stale bids
STALE=\$(echo \"\$BIDS\" | jq -r --arg cur \"\$CURRENT_HEIGHT\" --arg max \"\$MAX_BLOCKS\" '
  .bids[] | 
  select(((\$cur | tonumber) - (.bid.created_at | tonumber)) > (\$max | tonumber)) |
  \"\(.bid.id.dseq)|\(.bid.id.gseq)|\(.bid.id.oseq)|\(.bid.id.owner)|\(((\$cur | tonumber) - (.bid.created_at | tonumber)) * 6 / 3600 | floor)\"
')

if [ -z \"\$STALE\" ]; then
  echo 'No stale bids found (all bids are less than ${MAX_HOURS} hours old).'
  exit 0
fi

# Count stale bids
STALE_COUNT=\$(echo \"\$STALE\" | wc -l)
echo \"Found \$STALE_COUNT stale bid(s) to close:\"
echo ''

CLOSED=0
RECOVERED=0

for bid in \$STALE; do
  IFS='|' read -r dseq gseq oseq owner hours <<< \"\$bid\"
  echo \"Closing DSEQ \$dseq (age: \${hours}h)...\"
  
  RESULT=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
    provider-services tx market bid close \\
    --owner \$owner \\
    --dseq \$dseq \\
    --gseq \$gseq \\
    --oseq \$oseq \\
    --node http://akash-node-1:26657 \\
    --chain-id akashnet-2 \\
    --gas-prices 0.025uakt \\
    --gas auto \\
    --gas-adjustment 1.5 \\
    --from $PROVIDER \\
    -y 2>&1)
  
  if echo \"\$RESULT\" | grep -q '\"code\":0'; then
    echo \"   ✅ Closed successfully\"
    CLOSED=\$((CLOSED + 1))
    RECOVERED=\$(echo \"\$RECOVERED + 0.5\" | bc)
  else
    echo \"   ❌ Failed to close\"
    echo \"\$RESULT\" | grep -E 'error|failed' | head -1
  fi
  
  sleep 2
done

echo ''
echo '════════════════════════════════════════════════════════════════════'
echo \"Closed: \$CLOSED / \$STALE_COUNT bids\"
echo \"Escrow recovered: ~\${RECOVERED} AKT (minus gas fees)\"

# Show new balance
sleep 3
echo ''
echo 'New wallet balance:'
kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query bank balances $PROVIDER \\
  --node http://akash-node-1:26657 -o json 2>/dev/null | jq -r '.balances[] | \"   \(.amount | tonumber / 1000000) AKT\"'
"
