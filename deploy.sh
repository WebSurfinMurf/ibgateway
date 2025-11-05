#!/bin/bash

# Deploy IB Gateway
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Deploying IB Gateway..."

# Check if env file exists
if [ ! -f $HOME/projects/secrets/ibgateway.env ]; then
    echo "Error: $HOME/projects/secrets/ibgateway.env not found."
    echo "Please copy .env.example to $HOME/projects/secrets/ibgateway.env and configure it."
    exit 1
fi

# Create directories for volumes
mkdir -p jts ibc

# Pull latest image
docker compose pull

# Stop and remove existing container
docker compose down

# Start the service
docker compose up -d

echo "IB Gateway deployed successfully!"
echo ""
echo "Service is available on:"
echo "  - Paper trading: localhost:4002"
echo "  - Live trading:  localhost:4001"
echo "  - VNC (GUI):     localhost:5900"
echo ""
echo "Check logs with: docker compose logs -f"
