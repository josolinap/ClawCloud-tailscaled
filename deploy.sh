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

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check for required tools
    for tool in docker docker-compose curl openssl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
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

# Validate environment variables
validate_environment() {
    log "Validating environment variables..."
    
    if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
        error "TAILSCALE_AUTHKEY environment variable is required"
        error "Get your auth key from: https://login.tailscale.com/admin/settings/keys"
        exit 1
    fi
    
    # Validate authkey format
    if [[ ! "$TAILSCALE_AUTHKEY" =~ ^tskey-auth-[a-zA-Z0-9_-]+$ ]]; then
        error "TAILSCALE_AUTHKEY format appears invalid"
        exit 1
    fi
    
    # Set defaults
    export HOSTNAME="${HOSTNAME:-tailscale-exit-$(date +%s)}"
    export TZ="${TZ:-UTC}"
    export DISABLE_IPV6="${DISABLE_IPV6:-true}"
    
    success "Environment validation passed"
}

# Setup directories and permissions
setup_directories() {
    log "Setting up directories and permissions..."
    
    # Create required directories
    mkdir -p "${SCRIPT_DIR}/data/tailscale"
    mkdir -p "${SCRIPT_DIR}/logs/nginx"
    mkdir -p "${SCRIPT_DIR}/logs/tailscale"
    mkdir -p "${SCRIPT_DIR}/logs/supervisor"
    mkdir -p "${SCRIPT_DIR}/ssl"
    
    # Set proper permissions
    chmod 750 "${SCRIPT_DIR}/data/tailscale"
    chmod 755 "${SCRIPT_DIR}/logs"
    
    success "Directory setup complete"
}

# Generate SSL certificates if they don't exist
setup_ssl() {
    log "Setting up SSL certificates..."
    
    local cert_dir="${SCRIPT_DIR}/ssl"
    local cert_file="${cert_dir}/cert.pem"
    local key_file="${cert_dir}/key.pem"
    local dhparam_file="${cert_dir}/dhparam.pem"
    
    # Generate self-signed certificate if real certificates are not provided
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        warning "SSL certificates not found, generating self-signed certificate"
        warning "For production, replace with valid certificates from a CA"
        
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$key_file" \
            -out "$cert_file" \
            -subj "/C=US/ST=State/L=City/O=Organization/OU=OrgUnit/CN=${HOSTNAME}"
        
        chmod 600 "$key_file"
        chmod 644 "$cert_file"
    fi
    
    # Generate DH parameters if they don't exist
    if [ ! -f "$dhparam_file" ]; then
        log "Generating DH parameters (this may take a while)..."
        openssl dhparam -out "$dhparam_file" 2048
        chmod 644 "$dhparam_file"
    fi
    
    success "SSL setup complete"
}

# Run security scan
security_scan() {
    log "Running security scan..."
    
    # Check for common security issues in Dockerfile
    if command -v hadolint &> /dev/null; then
        log "Running Hadolint on Dockerfile..."
        hadolint Dockerfile.prod || warning "Hadolint found issues (see output above)"
    else
        warning "Hadolint not found, skipping Dockerfile security scan"
    fi
    
    # Check for secrets in environment
    if env | grep -i "password\|secret\|key" | grep -v "TAILSCALE_AUTHKEY"; then
        warning "Potential secrets found in environment variables"
    fi
    
    success "Security scan complete"
}

# Build the Docker image
build_image() {
    log "Building Docker image..."
    
    local build_date=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    local vcs_ref=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    
    export BUILD_DATE="$build_date"
    export VCS_REF="$vcs_ref"
    
    docker-compose -f docker-compose.prod.yml build --no-cache --pull
    
    success "Docker image built successfully"
}

# Deploy the service
deploy_service() {
    log "Deploying service..."
    
    # Stop existing containers
    docker-compose -f docker-compose.prod.yml down --remove-orphans || true
    
    # Start the service
    docker-compose -f docker-compose.prod.yml up -d
    
    success "Service deployed successfully"
}

# Wait for service to be healthy
wait_for_health() {
    log "Waiting for service to become healthy..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -f http://localhost/health &> /dev/null; then
            success "Service is healthy"
            return 0
        fi
        
        info "Health check attempt $attempt/$max_attempts failed, waiting..."
        sleep 10
        ((attempt++))
    done
    
    error "Service failed to become healthy after $max_attempts attempts"
    return 1
}

# Show deployment status
show_status() {
    log "Deployment status:"
    
    echo "=== Container Status ==="
    docker-compose -f docker-compose.prod.yml ps
    
    echo "=== Service Logs (last 20 lines) ==="
    docker-compose -f docker-compose.prod.yml logs --tail=20
    
    echo "=== Health Check ==="
    curl -s http://localhost/health && echo
    curl -s http://localhost/status && echo
    
    echo "=== Network Information ==="
    docker network ls | grep "$PROJECT_NAME" || echo "Using host network"
}

# Cleanup function
cleanup() {
    log "Cleaning up temporary files..."
    # Add any cleanup logic here
}

# Main deployment function
main() {
    log "Starting deployment of $PROJECT_NAME in $ENVIRONMENT environment"
    
    # Set up signal handlers
    trap cleanup EXIT
    
    # Run deployment steps
    check_prerequisites
    validate_environment
    setup_directories
    setup_ssl
    security_scan
    build_image
    deploy_service
    
    if wait_for_health; then
        success "Deployment completed successfully!"
        show_status
        
        echo ""
        echo "=== Next Steps ==="
        echo "1. Verify the exit node appears in your Tailscale admin panel"
        echo "2. Enable the exit node for your tailnet if needed"
        echo "3. Test connectivity from other devices"
        echo "4. Monitor logs: docker-compose -f docker-compose.prod.yml logs -f"
        echo "5. For production, replace self-signed SSL certificates with valid ones"
        
    else
        error "Deployment failed - service is not healthy"
        echo ""
        echo "=== Troubleshooting ==="
        echo "1. Check logs: docker-compose -f docker-compose.prod.yml logs"
        echo "2. Check container status: docker-compose -f docker-compose.prod.yml ps"
        echo "3. Verify TAILSCALE_AUTHKEY is correct and not expired"
        echo "4. Check network connectivity and firewall settings"
        exit 1
    fi
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy Tailscale Exit Node for production use on claw.cloud

Environment Variables:
  TAILSCALE_AUTHKEY   Required. Your Tailscale auth key
  HOSTNAME           Optional. Hostname for the exit node
  TZ                 Optional. Timezone (default: UTC)
  DISABLE_IPV6       Optional. Disable IPv6 (default: true)

Options:
  -h, --help         Show this help message
  --dry-run          Validate configuration without deploying
  --logs             Show service logs
  --status           Show service status
  --stop             Stop the service
  --clean            Stop service and remove all data

Examples:
  TAILSCALE_AUTHKEY=tskey-auth-xxx ./deploy.sh
  HOSTNAME=my-exit-node TAILSCALE_AUTHKEY=tskey-auth-xxx ./deploy.sh
EOF
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --dry-run)
        log "Dry run mode - validating configuration only"
        check_prerequisites
        validate_environment
        success "Configuration validation passed"
        exit 0
        ;;
    --logs)
        docker-compose -f docker-compose.prod.yml logs -f
        exit 0
        ;;
    --status)
        show_status
        exit 0
        ;;
    --stop)
        log "Stopping service..."
        docker-compose -f docker-compose.prod.yml down
        success "Service stopped"
        exit 0
        ;;
    --clean)
        log "Stopping service and cleaning up..."
        docker-compose -f docker-compose.prod.yml down -v --remove-orphans
        rm -rf "${SCRIPT_DIR}/data" "${SCRIPT_DIR}/logs"
        success "Cleanup complete"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        error "Unknown option: $1"
        usage
        exit 1
        ;;
esac
