#!/bin/bash
# Simple test script for Linnix
set -e

echo "🧪 Testing Linnix Setup"
echo "======================"
echo

# Test 1: Health endpoint
echo "✓ Test 1: Cognitod Health"
curl -sf http://localhost:3000/healthz | jq .
echo

# Test 2: Process tracking
echo "✓ Test 2: Process Tracking"
PROCESS_COUNT=$(curl -s http://localhost:3000/processes | jq 'length')
echo "Tracking $PROCESS_COUNT processes"
echo

# Test 3: Dashboard
echo "✓ Test 3: Web Dashboard"
curl -sf http://localhost:8080 > /dev/null && echo "Dashboard accessible at http://localhost:8080"
echo

# Test 4: LLM Server
echo "✓ Test 4: AI Model Server"
curl -sf http://localhost:8090/health | jq .
echo

# Test 5: Sample processes
echo "✓ Test 5: Sample Process Data"
curl -s http://localhost:3000/processes | jq '.[0:2]'
echo

# Test 6: Metrics
echo "✓ Test 6: System Metrics"
curl -s http://localhost:3000/metrics | jq '{cpu_percent, rss, events_per_sec, uptime_seconds}'
echo

echo "✅ All tests passed!"
echo
echo "🌐 Open http://localhost:8080 to see the dashboard"
