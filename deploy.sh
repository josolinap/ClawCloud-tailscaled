#!/bin/bash
# Enhanced deployment script for Tailscale Exit Node on claw.cloud
# Fully compatible with docker-compose.yml

set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="tailscale-exit-node"
ENVIRONMENT="${ENVIRONMENT:-production}"
LOG_FILE="${SCRIPT_DIR}/deploy.log"
DOCKER_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ------------------------------------------------------------
# Logging functions
# ------------------------------------------------------------
log()      { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }
error()    { echo -e "${RED}ERROR: $1${NC}" | tee -a "$LOG_FILE" >&2; }
warning()  { echo -e "${YELLOW}WARNING: $1${NC}" | tee -a "$LOG_FILE"; }
success()  { echo -e "${GREEN}SUCCESS: $1${NC}" | tee -a "$LOG_FILE"; }
info()     { echo -e "${BLUE}INFO: $1${NC}" | tee -a "$LOG_FILE"; }

# ------------------------------------------------------------
# Docker Compose wrapper
# ------------------------------------------------------------
docker_compose() {
    if command -v docker-compose &> /dev/null; then
        docker-compose -f "$DOCKER_COMPOSE_FILE" "$@"
    else
        docker compose -f "$DOCKER_COMPOSE_FILE" "$@"
    fi
}

# ------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------
check_prerequisites() {
    log "Checking prerequisites..."
    
    local missing_tools=()
    for tool in docker curl openssl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
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

# ------------------------------------------------------------
# Validate environment
# ------------------------------------------------------------
validate_environment() {
    log "Validating environment variables..."

    if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
        warning "TAILSCALE_AUTHKEY environment variable is not set."
        warning "Add it in Claw Cloud environment variables to enable deployment."
        return 0  # Don't exit, just warn
    fi

    # Validate authkey format if provided
    if [[ -n "$TAILSCALE_AUTHKEY" && ! "$TAILSCALE_AUTHKEY" =~ ^tskey-auth-[a-zA-Z0-9_-]+$ ]]; then
        error "TAILSCALE_AUTHKEY format appears invalid"
        exit 1
    fi

    # Set defaults
    export HOSTNAME="${HOSTNAME:-tailscale-exit-$(date +%s)}"
    export TZ="${TZ:-UTC}"
    export DISABLE_IPV6="${DISABLE_IPV6:-true}"

    success "Environment validation passed"
}

# ------------------------------------------------------------
# SSL setup
# ------------------------------------------------------------
setup_ssl() {
    log "Setting up SSL certificates..."
    mkdir -p "$SCRIPT_DIR/ssl"
    local cert="$SCRIPT_DIR/ssl/cert.pem"
    local key="$SCRIPT_DIR/ssl/key.pem"
    
    if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
        warning "SSL certificates not found, generating self-signed certificate"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$key" \
            -out "$cert" \
            -subj "/C=US/ST=State/L=City/O=Organization/OU=OrgUnit/CN=${HOSTNAME}"
        chmod 600 "$key"
        chmod 644 "$cert"
    fi
    success "SSL setup complete"
}

# ------------------------------------------------------------
# Build Docker image
# ------------------------------------------------------------
build_image() {
    log "Building Docker image..."
    docker_compose build --no-cache --pull
    success "Docker image built successfully"
}

# ------------------------------------------------------------
# Deploy service
# ------------------------------------------------------------
deploy_service() {
    log "Deploying service..."
    docker_compose down --remove-orphans || true
    docker_compose up -d
    success "Service deployed successfully"
}

# ------------------------------------------------------------
# Health check
# ------------------------------------------------------------
wait_for_health() {
    log "Waiting for service health..."
    local max_attempts=30
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if curl -sf http://localhost:5000/health &> /dev/null; then
            success "Service is healthy"
            return 0
        fi
        info "Health check attempt $attempt/$max_attempts failed..."
        sleep 10
        ((attempt++))
    done
    error "Service failed to become healthy after $max_attempts attempts"
    return 1
}

# ------------------------------------------------------------
# Show deployment status
# ------------------------------------------------------------
show_status() {
    log "Deployment status:"
    docker_compose ps
    docker_compose logs --tail=20
    curl -s http://localhost:5000/health && echo
    curl -s http://localhost:5000/status && echo
}

# ------------------------------------------------------------
# Main function
# ------------------------------------------------------------
main() {
    log "Starting deployment of $PROJECT_NAME"
    trap cleanup EXIT
    
    check_prerequisites
    validate_environment
    setup_ssl
    build_image
    deploy_service
    
    if wait_for_health; then
        success "Deployment completed successfully!"
        show_status
    else
        error "Deployment failed"
        exit 1
    fi
}

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
cleanup() {
    log "Cleaning up temporary files..."
}

# ------------------------------------------------------------
# CLI options
# ------------------------------------------------------------
case "${1:-}" in
    --logs)   docker_compose logs -f; exit 0 ;;
    --status) show_status; exit 0 ;;
    --stop)   log "Stopping service..."; docker_compose down; success "Service stopped"; exit 0 ;;
    --clean)  log "Cleaning service and data..."; docker_compose down -v --remove-orphans; rm -rf "${SCRIPT_DIR}/data" "${SCRIPT_DIR}/logs"; success "Cleanup complete"; exit 0 ;;
    "")       main ;;
    *)        error "Unknown option: $1"; exit 1 ;;
esac
