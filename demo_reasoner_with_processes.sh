#!/bin/bash
# Demo: Linnix Reasoner with Process Names

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Linnix Reasoner - Enhanced with Process Names"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check prerequisites
if ! curl -s http://localhost:8090/v1/models > /dev/null 2>&1; then
    echo "❌ Model server not running on port 8090"
    echo "   Start with: ./serve_distilled_model.sh"
    exit 1
fi

if ! curl -s http://localhost:3000/system > /dev/null 2>&1; then
    echo "❌ Cognitod not running on port 3000"
    exit 1
fi

echo "✅ Prerequisites checked"
echo ""

# Demo 1: Full analysis with process names
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Demo 1: Full System Analysis with Process Names"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

LLM_ENDPOINT="http://localhost:8090/v1/chat/completions" \
LLM_MODEL="linnix-3b-distilled" \
cargo run --release -p linnix-reasoner 2>&1 | tail -20

echo ""
echo ""

# Demo 2: Short summary mentioning processes
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 Demo 2: Short Summary Highlighting Key Processes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

LLM_ENDPOINT="http://localhost:8090/v1/chat/completions" \
LLM_MODEL="linnix-3b-distilled" \
cargo run --release -p linnix-reasoner -- --short 2>&1 | tail -10

echo ""
echo ""

# Demo 3: Show top processes directly
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔬 Demo 3: Current Top Processes (via ps)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Top 10 CPU-consuming processes:"
ps aux --sort=-%cpu | head -11

echo ""
echo "Top 10 Memory-consuming processes:"
ps aux --sort=-%mem | head -11

echo ""
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ Key Features Demonstrated:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Process names included in LLM analysis"
echo "✅ Top CPU consumers identified (e.g., VfsLoader, Worker threads)"
echo "✅ Top memory consumers highlighted"
echo "✅ PID + process name + resource % shown"
echo "✅ LLM provides context-aware recommendations"
echo "✅ Short summaries mention specific processes"
echo ""
echo "🎉 Demo complete!"
