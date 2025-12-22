#!/bin/bash
# Akash Provider - List Open Bids with Age
# Usage: ./akash-bids.sh

SERVER="root@178.63.224.202"
PROVIDER="akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf"

ssh $SERVER "
CURRENT_HEIGHT=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query block --node http://akash-node-1:26657 2>/dev/null | grep 'height:' | head -1 | awk '{print \$2}' | tr -d '\"')

echo '╔════════════════════════════════════════════════════════════════════╗'
echo '║             OPEN BIDS - '\$(date '+%Y-%m-%d %H:%M UTC')'                        ║'
echo '╚════════════════════════════════════════════════════════════════════╝'
echo ''
echo \"Current block height: \$CURRENT_HEIGHT\"
echo ''

BIDS=\$(kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query market bid list --provider $PROVIDER \\
  --state open --node http://akash-node-1:26657 -o json 2>/dev/null)

COUNT=\$(echo \"\$BIDS\" | jq '.bids | length')

if [ \"\$COUNT\" -eq 0 ]; then
  echo 'No open bids.'
  exit 0
fi

echo \"Found \$COUNT open bid(s):\"
echo ''
echo '┌──────────────┬────────────┬─────────────────┬─────────────────────┐'
echo '│ DSEQ         │ Age        │ Price/Block     │ Resources           │'
echo '├──────────────┼────────────┼─────────────────┼─────────────────────┤'

echo \"\$BIDS\" | jq -r --arg cur \"\$CURRENT_HEIGHT\" '
  .bids[] | 
  {
    dseq: .bid.id.dseq,
    blocks_ago: ((\$cur | tonumber) - (.bid.created_at | tonumber)),
    hours: (((\$cur | tonumber) - (.bid.created_at | tonumber)) * 6 / 3600),
    price: (.bid.price.amount | tonumber | . * 1000 | floor / 1000),
    denom: (if .bid.price.denom == \"uakt\" then \"uakt\" else \"USDC\" end),
    cpu: ((.bid.resources_offer[0].resources.cpu.units.val | tonumber) / 1000),
    mem: ((.bid.resources_offer[0].resources.memory.quantity.val | tonumber) / 1073741824)
  } | 
  \"│ \(.dseq | tostring | .[0:12] | . + \" \" * (12 - length)) │ \(.hours | floor)h         │ \(.price) \(.denom)     │ \(.cpu)cpu, \(.mem | . * 10 | floor / 10)GB        │\"
'

echo '└──────────────┴────────────┴─────────────────┴─────────────────────┘'
echo ''
echo 'Escrow locked: '\$COUNT' × 0.5 AKT = '\$(echo \"\$COUNT * 0.5\" | awk '{print \$1}')' AKT'
"
