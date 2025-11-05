#!/bin/bash
# Build and push Linnix Docker images to registry
#
# Usage:
#   ./build-and-push-images.sh [registry]
#
# Examples:
#   ./build-and-push-images.sh                    # Uses Docker Hub (linnixos)
#   ./build-and-push-images.sh ghcr.io/linnix-os  # Uses GitHub Container Registry

set -e

# Configuration
REGISTRY="${1:-linnixos}"  # Default to Docker Hub
VERSION="${VERSION:-v0.1.0}"
LATEST_TAG="latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  🐋 Linnix Docker Image Builder${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo "Registry: ${REGISTRY}"
echo "Version:  ${VERSION}"
echo

# Build cognitod image
echo -e "${BLUE}[1/3]${NC} Building cognitod image..."
docker build \
  -t ${REGISTRY}/cognitod:${VERSION} \
  -t ${REGISTRY}/cognitod:${LATEST_TAG} \
  -f Dockerfile \
  .

echo -e "${GREEN}✓${NC} cognitod image built successfully"
echo

# Build linnix-cli image (includes reasoner)
echo -e "${BLUE}[2/3]${NC} Building linnix-cli image..."
docker build \
  -t ${REGISTRY}/linnix-cli:${VERSION} \
  -t ${REGISTRY}/linnix-cli:${LATEST_TAG} \
  -f Dockerfile \
  --target cli \
  .

echo -e "${GREEN}✓${NC} linnix-cli image built successfully"
echo

# Build linnix-reasoner image
echo -e "${BLUE}[3/3]${NC} Building linnix-reasoner image..."
docker build \
  -t ${REGISTRY}/linnix-reasoner:${VERSION} \
  -t ${REGISTRY}/linnix-reasoner:${LATEST_TAG} \
  -f Dockerfile \
  --target reasoner \
  .

echo -e "${GREEN}✓${NC} linnix-reasoner image built successfully"
echo

# List built images
echo -e "${BLUE}Built images:${NC}"
docker images | grep "${REGISTRY}" | grep -E "(cognitod|linnix-cli|linnix-reasoner)"
echo

# Ask to push
read -p "Push images to registry? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Pushing images to ${REGISTRY}...${NC}"
    
    # Check if logged in
    if ! docker info | grep -q "Username"; then
        echo -e "${YELLOW}⚠ Not logged in to Docker registry${NC}"
        echo "Please login first:"
        echo "  Docker Hub: docker login"
        echo "  GitHub CR:  echo \$GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
        exit 1
    fi
    
    # Push cognitod
    echo "Pushing cognitod..."
    docker push ${REGISTRY}/cognitod:${VERSION}
    docker push ${REGISTRY}/cognitod:${LATEST_TAG}
    
    # Push linnix-cli
    echo "Pushing linnix-cli..."
    docker push ${REGISTRY}/linnix-cli:${VERSION}
    docker push ${REGISTRY}/linnix-cli:${LATEST_TAG}
    
    # Push linnix-reasoner
    echo "Pushing linnix-reasoner..."
    docker push ${REGISTRY}/linnix-reasoner:${VERSION}
    docker push ${REGISTRY}/linnix-reasoner:${LATEST_TAG}
    
    echo
    echo -e "${GREEN}✓ All images pushed successfully!${NC}"
    echo
    echo "Images available at:"
    echo "  ${REGISTRY}/cognitod:${VERSION}"
    echo "  ${REGISTRY}/cognitod:${LATEST_TAG}"
    echo "  ${REGISTRY}/linnix-cli:${VERSION}"
    echo "  ${REGISTRY}/linnix-cli:${LATEST_TAG}"
    echo "  ${REGISTRY}/linnix-reasoner:${VERSION}"
    echo "  ${REGISTRY}/linnix-reasoner:${LATEST_TAG}"
else
    echo "Skipping push. Images are built locally."
fi

echo
echo -e "${GREEN}✓ Done!${NC}"
