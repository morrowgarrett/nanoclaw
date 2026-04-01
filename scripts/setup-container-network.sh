#!/bin/bash
# Setup a restricted Docker network for NanoClaw agent containers.
# Containers can only reach:
#   - The credential proxy (host gateway)
#   - The memU sidecar (host gateway)
#   - PageForge (Tailscale)
#   - Google APIs (for Gmail/Calendar/Drive)
#   - Anthropic API (via credential proxy)
#
# Usage: sudo ./setup-container-network.sh

set -euo pipefail

NETWORK_NAME="nanoclaw-restricted"
SUBNET="172.30.0.0/16"

echo "Creating restricted Docker network: $NETWORK_NAME"

# Create network if it doesn't exist
if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
    docker network create \
        --driver bridge \
        --subnet "$SUBNET" \
        --opt "com.docker.network.bridge.name=br-nanoclaw" \
        "$NETWORK_NAME"
    echo "Network created: $NETWORK_NAME ($SUBNET)"
else
    echo "Network already exists: $NETWORK_NAME"
fi

# Get the bridge interface
BRIDGE_IF="br-nanoclaw"

# Allow DNS (needed for Google API resolution)
iptables -I DOCKER-USER -i "$BRIDGE_IF" -p udp --dport 53 -j ACCEPT
iptables -I DOCKER-USER -i "$BRIDGE_IF" -p tcp --dport 53 -j ACCEPT

# Allow access to host gateway (credential proxy on 3001, memU on 8100)
HOST_IP=$(docker network inspect "$NETWORK_NAME" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
iptables -I DOCKER-USER -i "$BRIDGE_IF" -d "$HOST_IP" -p tcp --dport 3001 -j ACCEPT
iptables -I DOCKER-USER -i "$BRIDGE_IF" -d "$HOST_IP" -p tcp --dport 8100 -j ACCEPT

# Allow HTTPS to Google APIs and Anthropic
iptables -I DOCKER-USER -i "$BRIDGE_IF" -p tcp --dport 443 -j ACCEPT

# Allow SSH to Surface Book (192.168.1.235)
iptables -I DOCKER-USER -i "$BRIDGE_IF" -d 192.168.1.235 -p tcp --dport 22 -j ACCEPT

# Allow Tailscale network (100.64.0.0/10)
iptables -I DOCKER-USER -i "$BRIDGE_IF" -d 100.64.0.0/10 -j ACCEPT

# Drop everything else from containers
iptables -A DOCKER-USER -i "$BRIDGE_IF" -j DROP

echo "Network restrictions applied."
echo ""
echo "To use: set CONTAINER_NETWORK=$NETWORK_NAME in .env"
echo "Or add --network $NETWORK_NAME to container-runner.ts"
