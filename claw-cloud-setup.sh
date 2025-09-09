#!/bin/bash
# Claw Cloud Host Setup Script
# This script installs and configures Tailscale on the host machine.
# Paste the contents of this script into your service's "Startup Script" in the Claw Cloud dashboard.

set -e

# --- Configuration ---
# IMPORTANT: Set your Tailscale Auth Key as a secret environment variable named
# TAILSCALE_AUTHKEY in your Claw Cloud service settings.

if [ -z "$TAILSCALE_AUTHKEY" ]; then
    echo "ERROR: TAILSCALE_AUTHKEY environment variable is not set. Please set it in the Claw Cloud dashboard."
    exit 1
fi

# --- Installation ---
echo "Installing Tailscale..."
# Add Tailscale's package repository and install
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
sudo apt-get update
sudo apt-get install tailscale -y

echo "Tailscale installed successfully."

# --- Configuration ---
echo "Configuring Tailscale to run as an exit node..."

# Enable IP forwarding on the host
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv6.conf.all.forwarding=1

# Start Tailscale with the necessary flags
sudo tailscale up \
    --authkey="${TAILSCALE_AUTHKEY}" \
    --advertise-exit-node \
    --hostname="claw-cloud-exit-node"

echo "Tailscale is configured and running as an exit node on the host."
echo "The Docker container will now start and have its traffic routed through this exit node."

# The script will exit, but Tailscale will continue running in the background.
# Your Docker container's command will be executed after this script completes.
