#!/bin/bash
# Enhanced run script for Tailscale Exit Node with IPv6 bypass
# This script runs the enhanced container with all optimizations

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="tailscale-exit-node-enhanced"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${BLUE}$(date '+%Y-%m-%d %H:%M:%S') - INFO: $1${NC}"
}

error() {
    echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1${NC}" >&2
}

success() {
    echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') - SUCCESS: $1${NC}"
}

warning() {
    echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') - WARNING: $1${NC}"
}

# Function to check if Docker is available
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is not installed or not in PATH"
        exit 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        error "Docker daemon is not running"
        exit 1
    fi
    
    success "Docker is available"
}

# Function to validate environment
validate_environment() {
    if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
        error "TAILSCALE_AUTHKEY environment variable is required"
        error "Get your auth key from: https://login.tailscale.com/admin/settings/keys"
        exit 1
    fi
    
    # Set defaults
    export HOSTNAME="${HOSTNAME:-tailscale-exit-$(date +%s)}"
    export TZ="${TZ:-UTC}"
    
    success "Environment validation passed"
}

# Function to create required directories
setup_directories() {
    log "Setting up directories..."
    
    mkdir -p "${SCRIPT_DIR}/logs"
    mkdir -p "${SCRIPT_DIR}/data"
    mkdir -p "${SCRIPT_DIR}/ssl"
    
    # Create self-signed SSL certificates if they don't exist
    if [ ! -f "${SCRIPT_DIR}/ssl/cert.pem" ] || [ ! -f "${SCRIPT_DIR}/ssl/key.pem" ]; then
        warning "SSL certificates not found, generating self-signed certificates"
        
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "${SCRIPT_DIR}/ssl/key.pem" \
            -out "${SCRIPT_DIR}/ssl/cert.pem" \
            -subj "/C=US/ST=State/L=City/O=Organization/OU=OrgUnit/CN=${HOSTNAME}" \
            2>/dev/null || warning "Could not generate SSL certificates"
    fi
    
    success "Directory setup complete"
}

# Function to build the enhanced image
build_image() {
    log "Building enhanced Docker image..."
    
    # Build with the enhanced Dockerfile
    if [ -f "${SCRIPT_DIR}/Dockerfile.enhanced" ]; then
        docker build -f "${SCRIPT_DIR}/Dockerfile.enhanced" -t "${PROJECT_NAME}:latest" .
    else
        # Fall back to regular Dockerfile with runtime optimizations
        docker build -t "${PROJECT_NAME}:latest" .
    fi
    
    success "Docker image built successfully"
}

# Function to run the container
run_container() {
    log "Starting enhanced Tailscale Exit Node container..."
    
    # Stop existing container if running
    docker rm -f "${PROJECT_NAME}" 2>/dev/null || true
    
    # Run with enhanced configuration
    docker run -d \
        --name "${PROJECT_NAME}" \
        --hostname "${HOSTNAME}" \
        --privileged \
        --network host \
        --restart unless-stopped \
        --env TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY}" \
        --env HOSTNAME="${HOSTNAME}" \
        --env TZ="${TZ}" \
        --env DISABLE_IPV6=true \
        --env TS_USERSPACE=true \
        --env TS_STATE_DIR=/var/lib/tailscale \
        --env TS_SOCKET=/var/run/tailscale/tailscaled.sock \
        --env TS_EXTRA_ARGS="--advertise-exit-node --accept-routes --netfilter-mode=off --reset" \
        --publish 5000:5000 \
        --sysctl net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl net.ipv6.conf.lo.disable_ipv6=1 \
        --sysctl net.ipv4.ip_forward=1 \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        --cap-add SYS_ADMIN \
        --memory 256m \
        --cpus 0.5 \
        --volume "${SCRIPT_DIR}/logs:/var/log" \
        --volume "${SCRIPT_DIR}/data:/var/lib/tailscale" \
        --volume "${SCRIPT_DIR}/ssl:/etc/ssl/certs:ro" \
        "${PROJECT_NAME}:latest"
    
    success "Container started successfully"
}

# Function to wait for container to be healthy
wait_for_health() {
    log "Waiting for container to become healthy..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "${PROJECT_NAME}.*healthy"; then
            success "Container is healthy"
            return 0
        fi
        
        if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "${PROJECT_NAME}"; then
            log "Container is running but not yet healthy (attempt $attempt/$max_attempts)"
        else
            error "Container is not running"
            return 1
        fi
        
        sleep 10
        attempt=$((attempt + 1))
    done
    
    warning "Container did not become healthy within expected time"
    return 1
}

# Function to show status
show_status() {
    log "Container status:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    echo ""
    log "Recent logs:"
    docker logs --tail 20 "${PROJECT_NAME}"
    
    echo ""
    log "Health check:"
    curl -s http://localhost:5000/health 2>/dev/null && echo || warning "Health endpoint not accessible"
}

# Main function
main() {
    log "=== Starting Enhanced Tailscale Exit Node ==="
    
    check_docker
    validate_environment
    setup_directories
    build_image
    run_container
    
    if wait_for_health; then
        success "Enhanced Tailscale Exit Node is running!"
        show_status
        
        echo ""
        log "=== Container Information ==="
        log "Name: ${PROJECT_NAME}"
        log "Hostname: ${HOSTNAME}"
        log "IPv6: Disabled"
        log "Bandwidth monitoring: Enabled"
        log "Health check: http://localhost/health"
        log "Status: http://localhost/status"
        
        echo ""
        log "View logs with: docker logs -f ${PROJECT_NAME}"
        log "Stop with: docker stop ${PROJECT_NAME}"
        
    else
        error "Failed to start enhanced container"
        echo ""
        log "Debugging information:"
        docker logs "${PROJECT_NAME}"
        exit 1
    fi
}

# Handle command line arguments
case "${1:-}" in
    --stop)
        log "Stopping container..."
        docker stop "${PROJECT_NAME}" 2>/dev/null || true
        docker rm "${PROJECT_NAME}" 2>/dev/null || true
        success "Container stopped"
        exit 0
        ;;
    --logs)
        docker logs -f "${PROJECT_NAME}"
        exit 0
        ;;
    --status)
        show_status
        exit 0
        ;;
    --build-only)
        check_docker
        setup_directories
        build_image
        success "Build complete"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        error "Unknown option: $1"
        echo "Usage: $0 [--stop|--logs|--status|--build-only]"
        exit 1
        ;;
esac
