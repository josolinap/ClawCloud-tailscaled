#!/bin/sh
# Production Docker entrypoint for Tailscale Exit Node
# Enhanced security and validation

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

error() {
    echo "${RED}ERROR: $1${NC}" >&2
}

warning() {
    echo "${YELLOW}WARNING: $1${NC}" >&2
}

success() {
    echo "${GREEN}SUCCESS: $1${NC}"
}

# Validate required environment variables
validate_env() {
    log "Validating environment variables..."
    
    if [ -z "$TAILSCALE_AUTHKEY" ]; then
        error "TAILSCALE_AUTHKEY environment variable is required"
        exit 1
    fi
    
    # Validate authkey format (basic check)
    if ! echo "$TAILSCALE_AUTHKEY" | grep -qE '^tskey-auth-[a-zA-Z0-9_-]+$'; then
        error "TAILSCALE_AUTHKEY format appears invalid"
        exit 1
    fi
    
    # Set default hostname if not provided
    if [ -z "$HOSTNAME" ]; then
        export HOSTNAME="exit-node-$(date +%s)"
        warning "HOSTNAME not set, using default: $HOSTNAME"
    fi
    
    success "Environment validation passed"
}

# Security hardening
setup_security() {
    log "Applying security hardening..."
    
    # Set secure umask
    umask 027
    
    # Create required directories with secure permissions
    mkdir -p /var/run/tailscale
    mkdir -p /var/log/tailscale
    mkdir -p /var/log/nginx
    mkdir -p /var/log/supervisor
    
    # Set proper ownership and permissions
    chown -R root:root /var/log/nginx /var/log/supervisor
    chown -R tailscale:tailscale /var/lib/tailscale /var/log/tailscale /var/run/tailscale
    chmod 750 /var/lib/tailscale /var/log/tailscale /var/run/tailscale
    chmod 640 /var/log/nginx/* /var/log/supervisor/* 2>/dev/null || true
    
    # Set sysctl values for security and performance
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || warning "Could not enable IP forwarding"
    sysctl -w net.ipv4.conf.all.accept_redirects=0 2>/dev/null || true
    sysctl -w net.ipv4.conf.all.send_redirects=0 2>/dev/null || true
    sysctl -w net.ipv4.conf.all.accept_source_route=0 2>/dev/null || true
    sysctl -w net.ipv4.conf.all.log_martians=1 2>/dev/null || true
    sysctl -w net.ipv4.tcp_syncookies=1 2>/dev/null || true
    
    # Disable IPv6 if not needed
    if [ "$DISABLE_IPV6" = "true" ]; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=1 2>/dev/null || true
    fi
    
    success "Security hardening applied"
}

# Test network connectivity
test_connectivity() {
    log "Testing network connectivity..."
    
    # Test DNS resolution
    if ! nslookup google.com >/dev/null 2>&1; then
        error "DNS resolution failed"
        exit 1
    fi
    
    # Test internet connectivity
    if ! curl -s --max-time 10 https://www.google.com >/dev/null 2>&1; then
        warning "Internet connectivity test failed, but continuing..."
    fi
    
    success "Network connectivity verified"
}

# Initialize tailscale state directory
init_tailscale() {
    log "Initializing Tailscale..."
    
    # Ensure state directory exists and has correct permissions
    if [ ! -d "/var/lib/tailscale" ]; then
        mkdir -p /var/lib/tailscale
        chown tailscale:tailscale /var/lib/tailscale
        chmod 750 /var/lib/tailscale
    fi
    
    success "Tailscale initialization complete"
}

# Health check function
health_check() {
    log "Performing initial health check..."
    
    # Check if required binaries exist
    if ! command -v tailscaled >/dev/null 2>&1; then
        error "tailscaled binary not found"
        exit 1
    fi
    
    if ! command -v tailscale >/dev/null 2>&1; then
        error "tailscale binary not found"
        exit 1
    fi
    
    if ! command -v nginx >/dev/null 2>&1; then
        error "nginx binary not found"
        exit 1
    fi
    
    if ! command -v supervisord >/dev/null 2>&1; then
        error "supervisord binary not found"
        exit 1
    fi
    
    success "Health check passed"
}

# Cleanup function for graceful shutdown
cleanup() {
    log "Shutting down gracefully..."
    
    # Stop tailscale if running
    if pgrep tailscaled >/dev/null; then
        log "Stopping tailscaled..."
        pkill -TERM tailscaled
        sleep 5
        pkill -KILL tailscaled 2>/dev/null || true
    fi
    
    # Stop nginx if running
    if pgrep nginx >/dev/null; then
        log "Stopping nginx..."
        pkill -TERM nginx
    fi
    
    log "Cleanup complete"
    exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT SIGQUIT

# Main execution
main() {
    log "Starting Tailscale Exit Node (Production Mode)"
    log "Version: 1.0.0"
    
    # Run all initialization steps
    validate_env
    health_check
    setup_security
    test_connectivity
    init_tailscale
    
    # Clear environment variables containing secrets
    unset KUBERNETES_SERVICE_HOST KUBERNETES_PORT KUBERNETES_PORT_443_TCP
    
    success "Initialization complete, starting services..."
    
    # Start supervisord in foreground
    exec "$@"
}

# Run main function with all arguments
main "$@"
