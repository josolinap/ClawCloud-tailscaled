#!/bin/bash
# Advanced deployment script for Tailscale Exit Node on claw.cloud
# Handles SSL auto-generation, validation, and health checks

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="tailscale-exit-node"
ENVIRONMENT="${ENVIRONMENT:-production}"
LOG_FILE="${SCRIPT_DIR}/deploy.log"
SSL_DIR="${SCRIPT_DIR}/ssl"
CERT_FILE="${SSL_DIR}/cert.pem"
KEY_FILE="${SSL_DIR}/key.pem"
DH_FILE="${SSL_DIR}/dhparam.pem"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}ERROR: $1${NC}" | tee -a "$LOG_FILE" >&2; }
warning() { echo -e "${YELLOW}WARNING: $1${NC}" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}SUCCESS: $1${NC}" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}INFO: $1${NC}" | tee -a "$LOG_FILE"; }

# Docker Compose wrapper
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
    for tool in docker curl openssl; do
        if ! command -v "$tool" &> /dev/null; then missing_tools+=("$tool"); fi
    done
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        missing_tools+=("docker-compose/docker compose")
    fi
    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running or accessible"
        exit 1
    fi
    success "Prerequisites check passed"
}

# Generate self-signed SSL if not exists
setup_ssl() {
    mkdir -p "$SSL_DIR"
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        warning "SSL certificates missing, generating self-signed cert"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/C=US/ST=State/L=City/O=Organization/OU=OrgUnit/CN=${HOSTNAME:-tailscale-exit-node}"
        chmod 600 "$KEY_FILE"
        chmod 644 "$CERT_FILE"
    fi
    if [ ! -f "$DH_FILE" ]; then
        log "Generating DH parameters (this may take a while)..."
        openssl dhparam -out "$DH_FILE" 2048
        chmod 644 "$DH_FILE"
    fi
    success "SSL setup complete"
}

# Build Docker image
build_image() {
    log "Building Docker image..."
    docker_compose build --no-cache --pull
    success "Docker image built successfully"
}

# Deploy service
deploy_service() {
    log "Deploying service..."
    docker_compose down --remove-orphans || true
    docker_compose up -d
    success "Service deployed successfully"
}

# Wait for Tailscale health
wait_for_health() {
    log "Waiting for Tailscale Exit Node health..."
    local max_attempts=30 attempt=1
    while [ $attempt -le $max_attempts ]; do
        if curl -f http://localhost:5000/health &> /dev/null; then
            success "Tailscale Exit Node is healthy"
            return 0
        fi
        info "Health check attempt $attempt/$max_attempts failed, retrying..."
        sleep 5
        ((attempt++))
    done
    error "Tailscale Exit Node failed to become healthy after $max_attempts attempts"
    return 1
}

# Show deployment status
show_status() {
    log "Deployment status:"
    echo "=== Container Status ==="
    docker_compose ps
    echo "=== Logs (last 20 lines) ==="
    docker_compose logs --tail=20
    echo "=== Health Check ==="
    curl -s http://localhost:5000/health && echo
    echo "=== Status Endpoint ==="
    curl -s http://localhost:5000/status && echo
    echo "=== Network Info ==="
    docker network ls | grep "$PROJECT_NAME" || echo "Using host network"
}

# Main deployment
main() {
    log "Starting deployment of $PROJECT_NAME in $ENVIRONMENT environment"
    trap cleanup EXIT
    check_prerequisites
    setup_ssl
    build_image
    deploy_service
    wait_for_health
    show_status
}

# Cleanup placeholder
cleanup() {
    log "Cleanup complete"
}

# CLI options
case "${1:-}" in
    --logs) docker_compose logs -f; exit 0 ;;
    --status) show_status; exit 0 ;;
    --stop) docker_compose down; success "Service stopped"; exit 0 ;;
    --clean) docker_compose down -v --remove-orphans; rm -rf "${SCRIPT_DIR}/data" "${SCRIPT_DIR}/logs"; success "Cleanup complete"; exit 0 ;;
    "") main ;;
    *) error "Unknown option: $1"; exit 1 ;;
esac
