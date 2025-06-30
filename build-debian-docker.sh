#!/bin/bash

# Docker-based Debian package build script for kvs-flare
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="flare-debian-builder"
CONTAINER_NAME="flare-build-$(date +%s)"

echo "=== Flare Debian Package Build (Docker) ==="
echo "Script directory: $SCRIPT_DIR"
echo "Docker image: $IMAGE_NAME"
echo "Container: $CONTAINER_NAME"

# Build the Docker image
echo "Building Docker image..."
docker build -f "$SCRIPT_DIR/Dockerfile.debian-build" -t "$IMAGE_NAME" "$SCRIPT_DIR"

# Create output directory
mkdir -p "$SCRIPT_DIR/debian-packages"

# Run the build container
echo "Running Debian package build in Docker..."
docker run --rm \
    --name "$CONTAINER_NAME" \
    --platform linux/x86_64 \
    -v "$SCRIPT_DIR/debian-packages:/output" \
    "$IMAGE_NAME"

echo ""
echo "=== Build Complete ==="
echo "Debian packages are available in: $SCRIPT_DIR/debian-packages/"
ls -la "$SCRIPT_DIR/debian-packages/"

echo ""
echo "To install the package:"
echo "  sudo dpkg -i $SCRIPT_DIR/debian-packages/kvs-flare*.deb"
echo "  sudo apt-get install -f  # to fix any dependency issues"