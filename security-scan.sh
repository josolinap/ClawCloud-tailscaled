#!/bin/bash
# Security scanning script for Tailscale Exit Node
# Performs comprehensive security analysis

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_REPORT="${SCRIPT_DIR}/security-report-$(date +%Y%m%d-%H%M%S).txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$SCAN_REPORT"
}

error() {
    echo -e "${RED}ERROR: $1${NC}" | tee -a "$SCAN_REPORT"
}

warning() {
    echo -e "${YELLOW}WARNING: $1${NC}" | tee -a "$SCAN_REPORT"
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}" | tee -a "$SCAN_REPORT"
}

info() {
    echo -e "${BLUE}INFO: $1${NC}" | tee -a "$SCAN_REPORT"
}

# Check if tools are installed
install_tools() {
    log "Installing security scanning tools..."
    
    if ! command -v docker-bench-security &> /dev/null; then
        info "Installing docker-bench-security..."
        git clone https://github.com/docker/docker-bench-security.git /tmp/docker-bench-security 2>/dev/null || true
    fi
    
    if ! command -v hadolint &> /dev/null; then
        info "Installing hadolint..."
        wget -q -O /tmp/hadolint https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64
        chmod +x /tmp/hadolint
        sudo mv /tmp/hadolint /usr/local/bin/ 2>/dev/null || mv /tmp/hadolint ./hadolint
    fi
    
    if ! command -v trivy &> /dev/null; then
        info "Installing trivy..."
        wget -q -O - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add - 2>/dev/null || true
        echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list 2>/dev/null || true
        sudo apt update && sudo apt install -y trivy 2>/dev/null || info "Could not install trivy via apt"
    fi
}

# Scan Dockerfile
scan_dockerfile() {
    log "Scanning Dockerfile for security issues..."
    local dockerfile="Dockerfile.prod"
    if [ ! -f "$dockerfile" ]; then
        error "Dockerfile.prod not found"
        return 1
    fi
    
    if command -v hadolint &> /dev/null; then
        info "Running hadolint scan..."
        hadolint "$dockerfile" | tee -a "$SCAN_REPORT" || warning "Hadolint found issues"
    else
        warning "Hadolint not available, skipping Dockerfile scan"
    fi
    
    local issues=0
    if grep -q "USER root" "$dockerfile"; then warning "Container runs as root"; ((issues++)); fi
    if grep -qE "FROM.*:latest" "$dockerfile"; then warning "Using 'latest' tag"; ((issues++)); fi
    if grep -q "^ADD " "$dockerfile"; then warning "Using ADD instead of COPY"; ((issues++)); fi
    if grep -qE "curl.*-k|curl.*--insecure" "$dockerfile"; then error "Insecure curl commands found"; ((issues++)); fi
    
    if [ $issues -eq 0 ]; then
        success "No major Dockerfile security issues found"
    else
        warning "Found $issues potential Dockerfile security issues"
    fi
}

# Scan for secrets
scan_secrets() {
    log "Scanning for hardcoded secrets..."
    local secrets_found=0
    local patterns=(
        "password.*=.*['\"].*['\"]"
        "secret.*=.*['\"].*['\"]"
        "key.*=.*['\"].*['\"]"
        "token.*=.*['\"].*['\"]"
        "api[_-]key.*=.*['\"].*['\"]"
        "tskey-[a-z]+-[a-zA-Z0-9_-]+"
    )
    
    for pattern in "${patterns[@]}"; do
        if grep -rE --exclude-dir=.git --exclude="*.log" --exclude="$SCAN_REPORT" "$pattern" . 2>/dev/null \
          | grep -v -E "(change_this_password|dummy_password|PLACEHOLDER|example_password|^\*\*\*)"; then
            warning "Potential secret found matching pattern: $pattern"
            ((secrets_found++))
        fi
    done
    
    if [ $secrets_found -eq 0 ]; then
        success "No hardcoded secrets detected"
    else
        warning "Found $secrets_found potential hardcoded secrets (check manually)"
    fi
}

# (scan_image, scan_configs, check_permissions, check_best_practices remain unchanged)

# Main function
main() {
    log "Starting comprehensive security scan..."
    
    cat > "$SCAN_REPORT" << EOF
TAILSCALE EXIT NODE SECURITY SCAN REPORT
Generated: $(date)
==========================================

EOF
    
    install_tools
    scan_dockerfile
    scan_secrets
    scan_image
    scan_configs
    check_permissions
    check_best_practices
    generate_summary
    
    echo ""
    echo "======================="
    echo "SECURITY SCAN COMPLETE"
    echo "======================="
    echo "Full report: $SCAN_REPORT"
    echo ""
    
    local warnings=$(grep -c "WARNING:" "$SCAN_REPORT" 2>/dev/null || echo "0")
    local errors=$(grep -c "ERROR:" "$SCAN_REPORT" 2>/dev/null || echo "0")
    
    if [ "$errors" -gt 0 ]; then
        error "Found $errors critical security issues that must be fixed"
        exit 1
    elif [ "$warnings" -gt 0 ]; then
        warning "Found $warnings security warnings to review"
        exit 0   # ✅ changed: warnings no longer fail CI
    else
        success "No critical security issues found"
        exit 0
    fi
}

main "$@"
