#!/bin/bash
# Deploy distilled 3B model for CPU-based production inference

set -e

DISTILLED_MODEL_PATH="${1:-$HOME/Downloads/linnix-qwen-distilled-3b-q5_k_m.gguf}"
TARGET_PATH="/usr/local/share/linnix/models/model.gguf"
CONFIG_PATH="/etc/linnix/linnix.toml"
BACKUP_SUFFIX=$(date +%Y%m%d_%H%M%S)

echo "🚀 Deploying Distilled Linnix Model (3B)"
echo "=========================================="

# Verify model exists
if [ ! -f "$DISTILLED_MODEL_PATH" ]; then
    echo "❌ Error: Model not found at $DISTILLED_MODEL_PATH"
    echo "Usage: $0 <path-to-distilled-model.gguf>"
    exit 1
fi

# Check model size (should be ~2GB for 3B Q5_K_M)
MODEL_SIZE=$(du -h "$DISTILLED_MODEL_PATH" | cut -f1)
echo "📦 Model size: $MODEL_SIZE"

# Backup current model
if [ -f "$TARGET_PATH" ]; then
    echo "💾 Backing up current model..."
    sudo cp "$TARGET_PATH" "${TARGET_PATH}.backup-${BACKUP_SUFFIX}"
fi

# Copy distilled model
echo "📋 Copying distilled model to $TARGET_PATH..."
sudo cp "$DISTILLED_MODEL_PATH" "$TARGET_PATH"

# Update config to use local endpoint (stop Colab dependency)
echo "⚙️  Updating configuration..."
if [ -f "$CONFIG_PATH" ]; then
    sudo cp "$CONFIG_PATH" "${CONFIG_PATH}.backup-${BACKUP_SUFFIX}"
    
    # Update endpoint to localhost
    sudo sed -i 's|endpoint = "https://.*ngrok.*"|endpoint = "http://localhost:8087/v1/chat/completions"|g' "$CONFIG_PATH"
    
    # Increase timeout for CPU inference (10s for GPU -> 15s for distilled CPU)
    sudo sed -i 's/timeout_ms = [0-9]*/timeout_ms = 15000/g' "$CONFIG_PATH"
    
    echo "✅ Updated config:"
    echo "   - endpoint: http://localhost:8087/v1/chat/completions"
    echo "   - timeout: 15 seconds"
fi

# Stop cognitod
echo "🛑 Stopping cognitod..."
sudo systemctl stop cognitod || true

# Start/restart LLM service
echo "🔄 Starting local LLM service..."
sudo systemctl enable linnix-llm
sudo systemctl restart linnix-llm

# Wait for service to start
echo "⏳ Waiting for LLM service to initialize..."
sleep 5

# Verify LLM is running
if curl -s http://localhost:8087/health > /dev/null 2>&1; then
    echo "✅ LLM service healthy"
else
    echo "⚠️  Warning: LLM service health check failed"
    echo "   Check logs: sudo journalctl -u linnix-llm -f"
fi

# Start cognitod
echo "🚀 Starting cognitod..."
sudo systemctl restart cognitod

echo ""
echo "✅ Deployment complete!"
echo ""
echo "📊 Expected performance:"
echo "   - Inference time: 5-10 seconds (vs 30-60s with 7.6B)"
echo "   - Quality: 90-95% of teacher model"
echo "   - Memory: ~3-4GB RAM"
echo "   - Cost: $0/month (no GPU needed)"
echo ""
echo "🔍 Monitor with:"
echo "   sudo journalctl -u linnix-llm -f    # LLM logs"
echo "   sudo journalctl -u cognitod -f      # Daemon logs"
echo "   curl http://localhost:3000/insights # Test insights"
echo ""
echo "💡 To rollback:"
echo "   sudo cp ${TARGET_PATH}.backup-${BACKUP_SUFFIX} $TARGET_PATH"
echo "   sudo systemctl restart linnix-llm cognitod"
