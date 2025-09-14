#!/bin/bash
# Enhanced entrypoint script with comprehensive IPv6 bypass and claw.cloud adaptations

set -euo pipefail

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ENTRYPOINT: $1"
}

error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ENTRYPOINT ERROR: $1" >&2
}

log "Starting Tailscale Exit Node with IPv6 bypass..."

# Function to disable IPv6 at multiple levels with extensive fallback
disable_ipv6() {
    log "Attempting comprehensive IPv6 disable..."
    
    # Method 1: sysctl (try various approaches)
    local ipv6_disabled=false
    
    # Try to disable IPv6 via sysctl (will fail in unprivileged containers)
    if sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null; then
        log "IPv6 disabled via sysctl (all interfaces)"
        ipv6_disabled=true
    else
        log "Failed to disable IPv6 via sysctl - trying alternatives"
    fi
    
    # Try individual interface disabling
    for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        if echo 1 > "$iface" 2>/dev/null; then
            log "IPv6 disabled on interface: $(basename $(dirname $iface))"
            ipv6_disabled=true
        fi
    done
    
    # Method 2: Environment-based approach (Tailscale-specific)
    export TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-} --netfilter-mode=off"
    if [ "${DISABLE_IPV6:-true}" = "true" ]; then
        export TS_USERSPACE=true
        log "Enabled Tailscale userspace networking (IPv6 bypass)"
    fi
    
    # Method 3: IP link manipulation (try to down IPv6 interfaces)
    if command -v ip >/dev/null 2>&1; then
        ip -6 addr flush dev lo 2>/dev/null || true
        log "Attempted IPv6 address flush on loopback"
    fi
    
    if [ "$ipv6_disabled" = "true" ]; then
        log "IPv6 successfully disabled using available methods"
    else
        log "WARNING: Could not fully disable IPv6 - continuing with userspace mode"
    fi
}

# Function to detect and adapt to claw.cloud networking
detect_cloud_environment() {
    log "Detecting claw.cloud environment and network configuration..."
    
    # Check for claw.cloud specific environment
    if [ -n "${CLAWCLOUD_INSTANCE:-}" ] || [ -n "${CLAW_INSTANCE_ID:-}" ]; then
        log "Detected claw.cloud environment"
        export CLOUD_PROVIDER="clawcloud"
    fi
    
    # Get network information
    local external_ip=$(curl -s --max-time 10 ipinfo.io/ip 2>/dev/null || echo "unknown")
    local internal_ip=$(hostname -i 2>/dev/null || echo "unknown")
    
    log "External IP: $external_ip"
    log "Internal IP: $internal_ip"
    
    # Adjust Tailscale settings for cloud environment
    if [ "$external_ip" != "$internal_ip" ] && [ "$external_ip" != "unknown" ]; then
        log "Detected NAT environment - adjusting Tailscale configuration"
        export TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-} --advertise-exit-node --accept-routes"
    fi
}

# Function to configure Tailscale with extensive error handling
configure_tailscale() {
    log "Configuring Tailscale daemon..."
    
    # Validate auth key
    if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
        error "TAILSCALE_AUTHKEY environment variable is required"
        exit 1
    fi
    
    # Set Tailscale hostname
    export TS_HOSTNAME="${HOSTNAME:-tailscale-exit-$(date +%s)}"
    
    # Configure Tailscale directories
    mkdir -p "${TS_STATE_DIR:-/var/lib/tailscale}" "$(dirname ${TS_SOCKET:-/var/run/tailscale/tailscaled.sock})"
    
    # Set additional Tailscale environment variables
    export TS_AUTHKEY="${TAILSCALE_AUTHKEY}"
    export TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-} --advertise-exit-node --accept-routes --reset"
    
    log "Tailscale configuration complete"
    log "Hostname: $TS_HOSTNAME"
    log "Extra args: $TS_EXTRA_ARGS"
    log "Userspace mode: ${TS_USERSPACE:-false}"
}

# Function to start services
start_services() {
    log "Starting services..."
    
    # Create required directories
    mkdir -p /var/log/supervisor /var/lib/tailscale/bandwidth
    
    # Start bandwidth monitoring if script exists
    if [ -f /usr/local/bin/bandwidth-monitor.sh ]; then
        /usr/local/bin/bandwidth-monitor.sh &
        log "Bandwidth monitoring started"
    fi
    
    # Start supervisor
    log "Starting supervisord..."
    exec supervisord -n -c /etc/supervisor/supervisord.conf
}

# Main execution
main() {
    log "=== Tailscale Exit Node Enhanced Startup ==="
    
    # Execute startup sequence
    disable_ipv6
    detect_cloud_environment  
    configure_tailscale
    start_services
}

# Clear any kubernetes environment variables that might interfere
unset KUBERNETES_SERVICE_HOST KUBERNETES_PORT KUBERNETES_PORT_443_TCP 2>/dev/null || true

# Run main function
main
