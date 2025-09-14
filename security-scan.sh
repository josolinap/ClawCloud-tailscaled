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
    
    # Install Docker security tools
    if ! command -v docker-bench-security &> /dev/null; then
        info "Installing docker-bench-security..."
        git clone https://github.com/docker/docker-bench-security.git /tmp/docker-bench-security 2>/dev/null || true
    fi
    
    # Install Hadolint
    if ! command -v hadolint &> /dev/null; then
        info "Installing hadolint..."
        wget -q -O /tmp/hadolint https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64
        chmod +x /tmp/hadolint
        sudo mv /tmp/hadolint /usr/local/bin/ 2>/dev/null || mv /tmp/hadolint ./hadolint
    fi
    
    # Install Trivy
    if ! command -v trivy &> /dev/null; then
        info "Installing trivy..."
        wget -q -O - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add - 2>/dev/null || true
        echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list 2>/dev/null || true
        sudo apt update && sudo apt install -y trivy 2>/dev/null || info "Could not install trivy via apt"
    fi
}

# Scan Dockerfile for security issues
scan_dockerfile() {
    log "Scanning Dockerfile for security issues..."
    
    local dockerfile="Dockerfile.prod"
    if [ ! -f "$dockerfile" ]; then
        error "Dockerfile.prod not found"
        return 1
    fi
    
    # Use hadolint if available
    if command -v hadolint &> /dev/null; then
        info "Running hadolint scan..."
        hadolint "$dockerfile" | tee -a "$SCAN_REPORT" || warning "Hadolint found issues"
    else
        warning "Hadolint not available, skipping Dockerfile scan"
    fi
    
    # Manual checks
    info "Performing manual Dockerfile security checks..."
    
    local issues=0
    
    # Check for running as root
    if grep -q "USER root" "$dockerfile"; then
        warning "Container runs as root user - security risk"
        ((issues++))
    fi
    
    # Check for latest tags
    if grep -qE "FROM.*:latest" "$dockerfile"; then
        warning "Using 'latest' tag - pin to specific versions"
        ((issues++))
    fi
    
    # Check for ADD instead of COPY
    if grep -q "^ADD " "$dockerfile"; then
        warning "Using ADD instead of COPY - potential security risk"
        ((issues++))
    fi
    
    # Check for curl without verification
    if grep -qE "curl.*-k|curl.*--insecure" "$dockerfile"; then
        error "Insecure curl commands found"
        ((issues++))
    fi
    
    if [ $issues -eq 0 ]; then
        success "No major Dockerfile security issues found"
    else
        warning "Found $issues potential Dockerfile security issues"
    fi
}

# Scan for hardcoded secrets
scan_secrets() {
    log "Scanning for hardcoded secrets..."
    
    local secrets_found=0
    
    # Common secret patterns
    local patterns=(
        "password.*=.*['\"].*['\"]"
        "secret.*=.*['\"].*['\"]"
        "key.*=.*['\"].*['\"]"
        "token.*=.*['\"].*['\"]"
        "api[_-]key.*=.*['\"].*['\"]"
        "tskey-[a-z]+-[a-zA-Z0-9_-]+"
    )
    
    for pattern in "${patterns[@]}"; do
        if grep -rE --exclude-dir=.git --exclude="*.log" --exclude="$SCAN_REPORT" "$pattern" . 2>/dev/null; then
            warning "Potential secret found matching pattern: $pattern"
            ((secrets_found++))
        fi
    done
    
    if [ $secrets_found -eq 0 ]; then
        success "No hardcoded secrets detected"
    else
        error "Found $secrets_found potential hardcoded secrets"
    fi
}

# Scan container image for vulnerabilities
scan_image() {
    log "Scanning Docker image for vulnerabilities..."
    
    local image_name="tailscale-exit-node-prod"
    
    # Build image if it doesn't exist
    if ! docker image inspect "$image_name" &> /dev/null; then
        info "Image not found, building..."
        docker build -f Dockerfile.prod -t "$image_name" . || {
            error "Failed to build image for scanning"
            return 1
        }
    fi
    
    # Use Trivy if available
    if command -v trivy &> /dev/null; then
        info "Running Trivy vulnerability scan..."
        trivy image "$image_name" | tee -a "$SCAN_REPORT" || warning "Trivy scan completed with issues"
    else
        warning "Trivy not available, skipping image vulnerability scan"
    fi
    
    # Docker security baseline
    if [ -d "/tmp/docker-bench-security" ]; then
        info "Running Docker Bench Security..."
        cd /tmp/docker-bench-security
        ./docker-bench-security.sh | tee -a "$SCAN_REPORT" || warning "Docker Bench found issues"
        cd "$SCRIPT_DIR"
    else
        warning "Docker Bench Security not available"
    fi
}

# Check configuration security
scan_configs() {
    log "Scanning configuration files for security issues..."
    
    local config_issues=0
    
    # Check nginx configuration
    if [ -f "nginx.prod.conf" ]; then
        info "Checking nginx configuration..."
        
        # Check for security headers
        local required_headers=(
            "add_header Strict-Transport-Security"
            "add_header X-Frame-Options"
            "add_header X-Content-Type-Options"
            "add_header X-XSS-Protection"
        )
        
        for header in "${required_headers[@]}"; do
            if ! grep -q "$header" nginx.prod.conf; then
                warning "Missing security header: $header"
                ((config_issues++))
            fi
        done
        
        # Check SSL configuration
        if ! grep -q "ssl_protocols TLSv1.3" nginx.prod.conf; then
            warning "Not enforcing TLS 1.3 only"
            ((config_issues++))
        fi
        
        if grep -q "ssl_protocols.*TLSv1\.2" nginx.prod.conf; then
            info "TLS 1.2 is enabled - consider TLS 1.3 only for maximum security"
        fi
    fi
    
    # Check supervisor configuration
    if [ -f "supervisord.prod.conf" ]; then
        info "Checking supervisor configuration..."
        
        if grep -q "password=change_this_password" supervisord.prod.conf; then
            error "Default supervisor password detected - change immediately!"
            ((config_issues++))
        fi
    fi
    
    if [ $config_issues -eq 0 ]; then
        success "Configuration security checks passed"
    else
        warning "Found $config_issues configuration security issues"
    fi
}

# Check file permissions
check_permissions() {
    log "Checking file permissions..."
    
    local perm_issues=0
    
    # Check for overly permissive files
    if find . -type f -perm /o+w -not -path "./.git/*" -not -name "$SCAN_REPORT" | grep -q .; then
        warning "World-writable files found:"
        find . -type f -perm /o+w -not -path "./.git/*" -not -name "$SCAN_REPORT" | tee -a "$SCAN_REPORT"
        ((perm_issues++))
    fi
    
    # Check shell scripts are executable
    for script in *.sh; do
        if [ -f "$script" ] && [ ! -x "$script" ]; then
            warning "Shell script $script is not executable"
            ((perm_issues++))
        fi
    done
    
    if [ $perm_issues -eq 0 ]; then
        success "File permissions check passed"
    else
        warning "Found $perm_issues permission issues"
    fi
}

# Check for security best practices
check_best_practices() {
    log "Checking security best practices implementation..."
    
    local practices_score=0
    local total_practices=10
    
    # Check if fail2ban is configured
    if [ -f "fail2ban.conf" ]; then
        success "✓ Fail2ban configured"
        ((practices_score++))
    else
        warning "✗ Fail2ban not configured"
    fi
    
    # Check if HTTPS is enforced
    if grep -q "return 301 https" nginx.prod.conf 2>/dev/null; then
        success "✓ HTTP to HTTPS redirect configured"
        ((practices_score++))
    else
        warning "✗ HTTP to HTTPS redirect not found"
    fi
    
    # Check if rate limiting is configured
    if grep -q "limit_req_zone" nginx.prod.conf 2>/dev/null; then
        success "✓ Rate limiting configured"
        ((practices_score++))
    else
        warning "✗ Rate limiting not configured"
    fi
    
    # Check if health checks are configured
    if grep -q "healthcheck" docker-compose.prod.yml 2>/dev/null; then
        success "✓ Health checks configured"
        ((practices_score++))
    else
        warning "✗ Health checks not configured"
    fi
    
    # Check if logging is configured
    if [ -d "logs" ] || grep -q "logfile" supervisord.prod.conf 2>/dev/null; then
        success "✓ Logging configured"
        ((practices_score++))
    else
        warning "✗ Logging not properly configured"
    fi
    
    # Check if SSL is configured
    if [ -d "ssl" ] || grep -q "ssl_certificate" nginx.prod.conf 2>/dev/null; then
        success "✓ SSL/TLS configured"
        ((practices_score++))
    else
        warning "✗ SSL/TLS not configured"
    fi
    
    # Check if resource limits are set
    if grep -q "limits:" docker-compose.prod.yml 2>/dev/null; then
        success "✓ Resource limits configured"
        ((practices_score++))
    else
        warning "✗ Resource limits not configured"
    fi
    
    # Check if non-root user is configured where possible
    if grep -q "adduser.*tailscale" Dockerfile.prod 2>/dev/null; then
        success "✓ Non-root user configured"
        ((practices_score++))
    else
        warning "✗ Non-root user not configured"
    fi
    
    # Check if secrets are externalized
    if ! grep -rE "password.*=" . --exclude="$SCAN_REPORT" --exclude-dir=.git 2>/dev/null | grep -v "change_this_password" | grep -q .; then
        success "✓ No hardcoded passwords found"
        ((practices_score++))
    else
        warning "✗ Potential hardcoded passwords found"
    fi
    
    # Check if monitoring is configured
    if [ -f "monitoring/prometheus.yml" ]; then
        success "✓ Monitoring configured"
        ((practices_score++))
    else
        warning "✗ Monitoring not configured"
    fi
    
    info "Security best practices score: $practices_score/$total_practices"
    
    if [ $practices_score -ge 8 ]; then
        success "Excellent security posture!"
    elif [ $practices_score -ge 6 ]; then
        warning "Good security posture, some improvements possible"
    else
        error "Security posture needs improvement"
    fi
}

# Generate security summary
generate_summary() {
    log "Generating security scan summary..."
    
    cat >> "$SCAN_REPORT" << EOF

=====================================
SECURITY SCAN SUMMARY
=====================================
Scan Date: $(date)
Project: Tailscale Exit Node
Environment: Production

RECOMMENDATIONS:
1. Replace self-signed SSL certificates with CA-signed certificates
2. Change default supervisor password in supervisord.prod.conf
3. Regularly update base images and dependencies
4. Monitor logs for suspicious activity
5. Keep Tailscale client updated to latest version
6. Implement log aggregation and monitoring
7. Regular security scans and updates
8. Backup and disaster recovery procedures

NEXT STEPS:
- Review all WARNING and ERROR items above
- Update configurations as needed
- Re-run security scan after fixes
- Schedule regular security assessments

For production deployment:
- Use secrets management (e.g., Kubernetes secrets, HashiCorp Vault)
- Implement proper SSL certificate management
- Set up monitoring and alerting
- Configure automated backups
- Document incident response procedures
=====================================
EOF

    success "Security scan complete. Report saved to: $SCAN_REPORT"
}

# Main function
main() {
    log "Starting comprehensive security scan..."
    
    # Create report header
    cat > "$SCAN_REPORT" << EOF
TAILSCALE EXIT NODE SECURITY SCAN REPORT
Generated: $(date)
==========================================

EOF
    
    # Run all security checks
    install_tools
    scan_dockerfile
    scan_secrets
    scan_image
    scan_configs
    check_permissions
    check_best_practices
    generate_summary
    
    # Display summary
    echo ""
    echo "======================="
    echo "SECURITY SCAN COMPLETE"
    echo "======================="
    echo "Full report: $SCAN_REPORT"
    echo ""
    
    # Show quick summary
    local warnings=$(grep -c "WARNING:" "$SCAN_REPORT" 2>/dev/null || echo "0")
    local errors=$(grep -c "ERROR:" "$SCAN_REPORT" 2>/dev/null || echo "0")
    
    if [ "$errors" -gt 0 ]; then
        error "Found $errors critical security issues that must be fixed"
        exit 1
    elif [ "$warnings" -gt 0 ]; then
        warning "Found $warnings security warnings to review"
        exit 2
    else
        success "No critical security issues found"
        exit 0
    fi
}

# Run main function
main "$@"
