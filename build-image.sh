#!/bin/bash
# Quick script to build Linnix Docker images
# Run this, then login and push manually

set -e

echo "🐋 Building Linnix Docker images..."
echo

# Build main cognitod image
echo "[1/1] Building cognitod (this will take 10-15 minutes)..."
sudo docker build \
  -t linnixos/cognitod:latest \
  -t linnixos/cognitod:v0.1.0 \
  .

echo
echo "✅ Build complete!"
echo
echo "Images built:"
sudo docker images | grep linnixos/cognitod
echo
echo "To push to Docker Hub:"
echo "  1. docker login"
echo "  2. docker push linnixos/cognitod:latest"
echo "  3. docker push linnixos/cognitod:v0.1.0"
