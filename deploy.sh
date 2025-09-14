#!/bin/bash
# Production deployment script for Tailscale Exit Node on claw.cloud
# This script handles secure deployment with proper validation

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="tailscale-exit-node"
ENVIRONMENT="${ENVIRONMENT:-production}"
LOG_FILE="${SCRIPT_DIR}/deploy.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}ERROR: $1${NC}" | tee -a "$LOG_FILE" >&2
}

warning() {
    echo -e "${YELLOW}WARNING: $1${NC}" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}INFO: $1${NC}" | tee -a "$LOG_FILE"
}

# Wrapper for docker compose compatibility
docker_compose() {
    if command -v docker-compose &> /dev/null; then
        docker-compose "$@"
    else
        docker compose "$@"
    fi
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check for required tools
    for tool in docker curl openssl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    # Check for docker-compose OR docker compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        missing_tools+=("docker-compose/docker compose")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running or accessible"
        exit 1
    fi
    
    success "Prerequisites check passed"
}

# Build the Docker image
build_image() {
    log "Building Docker image..."
    
    local build_date=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    local vcs_ref=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    
    export BUILD_DATE="$build_date"
    export VCS_REF="$vcs_ref"
    
    docker_compose -f docker-compose.prod.yml build --no-cache --pull
    
    success "Docker image built successfully"
}

# Deploy the service
deploy_service() {
    log "Deploying service..."
    
    # Stop existing containers
    docker_compose -f docker-compose.prod.yml down --remove-orphans || true
    
    # Start the service
    docker_compose -f docker-compose.prod.yml up -d
    
    success "Service deployed successfully"
}

# Show deployment status
show_status() {
    log "Deployment status:"
    
    echo "=== Container Status ==="
    docker_compose -f docker-compose.prod.yml ps
    
    echo "=== Service Logs (last 20 lines) ==="
    docker_compose -f docker-compose.prod.yml logs --tail=20
    
    echo "=== Health Check ==="
    curl -s http://localhost/health && echo
    curl -s http://localhost/status && echo
    
    echo "=== Network Information ==="
    docker network ls | grep "$PROJECT_NAME" || echo "Using host network"
}

# CLI options patched
case "${1:-}" in
    --logs)
        docker_compose -f docker-compose.prod.yml logs -f
        exit 0
        ;;
    --status)
        show_status
        exit 0
        ;;
    --stop)
        log "Stopping service..."
        docker_compose -f docker-compose.prod.yml down
        success "Service stopped"
        exit 0
        ;;
    --clean)
        log "Stopping service and cleaning up..."
        docker_compose -f docker-compose.prod.yml down -v --remove-orphans
        rm -rf "${SCRIPT_DIR}/data" "${SCRIPT_DIR}/logs"
        success "Cleanup complete"
        exit 0
        ;;
    # ... rest stays unchanged ...
esac
