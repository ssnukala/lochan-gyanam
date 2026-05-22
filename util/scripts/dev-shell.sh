#!/bin/bash
# Start or attach to the Vardhan dev container
# Usage: ./util/scripts/dev-shell.sh
#
# First run builds the image. Subsequent runs reuse it.
# Mounts gyanam/ as /gyanam, loads API keys from util/.env

set -euo pipefail
cd "$(dirname "$0")/../.."

CONTAINER_NAME="vardhan-dev"
IMAGE_NAME="vardhan-dev"

# Build if image doesn't exist
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Building vardhan-dev image..."
    docker build -t "$IMAGE_NAME" util/
fi

# Check if container is already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Attaching to running container..."
    docker exec -it "$CONTAINER_NAME" bash
else
    echo "Starting vardhan-dev container..."
    docker run -it --rm \
        --name "$CONTAINER_NAME" \
        -v "$(pwd):/gyanam" \
        -v "$(dirname $(pwd)):/docker" \
        -w /gyanam \
        --env-file util/.env \
        --network host \
        "$IMAGE_NAME" \
        bash
fi
