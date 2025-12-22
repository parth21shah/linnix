#!/bin/bash
# Akash Provider - Quick Balance Check
# Usage: ./akash-balance.sh

SERVER="root@178.63.224.202"
PROVIDER="akash1lvsmef72t8ecgse02eqa25tnt68e8gdlc67dpf"

ssh $SERVER "
kubectl exec -n akash-services akash-provider-0 -c provider -- \\
  provider-services query bank balances $PROVIDER \\
  --node http://akash-node-1:26657 -o json 2>/dev/null | \\
  jq -r '.balances[] | \"\(.amount | tonumber / 1000000) AKT\"'
"
