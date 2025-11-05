#!/bin/bash
# Push images to GitHub Container Registry
# Make sure you've run build-ghcr.sh first and are logged in

set -e

REGISTRY="ghcr.io/linnix-os"
VERSION="v0.1.0"

echo "📦 Pushing images to GitHub Container Registry..."
echo

# Push images (using sudo)
echo "Pushing ${REGISTRY}/cognitod:${VERSION}..."
sudo -E docker push ${REGISTRY}/cognitod:${VERSION}

echo "Pushing ${REGISTRY}/cognitod:latest..."
sudo -E docker push ${REGISTRY}/cognitod:latest

echo
echo "✅ Images pushed successfully!"
echo
echo "Images available at:"
echo "  ${REGISTRY}/cognitod:${VERSION}"
echo "  ${REGISTRY}/cognitod:latest"
echo
echo "Update docker-compose.yml to use: image: ${REGISTRY}/cognitod:latest"
