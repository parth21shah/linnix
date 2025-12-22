#!/usr/bin/env bash
#
# test_build_only.sh - Just build the Docker image to verify it works
#
set -euo pipefail

echo "Building Docker image..."
cd "$(dirname "$0")"

docker-compose build guardian 2>&1 | tee build.log

if [ $? -eq 0 ]; then
    echo "✅ Docker image built successfully!"
    docker images | grep linnix
else
    echo "❌ Docker build failed"
    exit 1
fi
