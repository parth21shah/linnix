#!/bin/bash
# Build and push to GitHub Container Registry
# Usage: ./build-ghcr.sh

set -e

REGISTRY="ghcr.io/linnix-os"
VERSION="v0.1.0"

echo "🐋 Building Linnix Docker images for GitHub Container Registry..."
echo "Registry: $REGISTRY"
echo

# Build cognitod image
echo "[1/1] Building cognitod..."
sudo docker build \
  -t ${REGISTRY}/cognitod:${VERSION} \
  -t ${REGISTRY}/cognitod:latest \
  .

echo
echo "✅ Build complete!"
echo
echo "Images built:"
sudo docker images | grep "ghcr.io/linnix-os"
echo
echo "To push to GitHub Container Registry:"
echo "  1. Create a GitHub Personal Access Token with 'write:packages' scope"
echo "  2. export CR_PAT=YOUR_TOKEN"
echo "  3. echo \$CR_PAT | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin"
echo "  4. docker push ${REGISTRY}/cognitod:${VERSION}"
echo "  5. docker push ${REGISTRY}/cognitod:latest"
echo
echo "Or run: ./push-ghcr.sh"
