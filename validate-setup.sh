#!/bin/bash
# Validation script to ensure production readiness
# Checks all components before deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

success=0
warnings=0
errors=0

check() {
    if eval "$2"; then
        echo -e "${GREEN}✓ $1${NC}"
        ((success++))
    else
        echo -e "${RED}✗ $1${NC}"
        ((errors++))
    fi
}

warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
    ((warnings++))
}

info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

echo "==========================================="
echo "  TAILSCALE EXIT NODE VALIDATION"
echo "  Production Readiness Check"
echo "==========================================="
echo

# Check required files exist
echo "📁 Checking required files..."
check "Production Dockerfile exists" "[ -f 'Dockerfile.prod' ]"
check "Production docker-compose exists" "[ -f 'docker-compose.prod.yml' ]"
check "Nginx production config exists" "[ -f 'nginx.prod.conf' ]"
check "Supervisord production config exists" "[ -f 'supervisord.prod.conf' ]"
check "Production entrypoint script exists" "[ -f 'docker-entrypoint.prod.sh' ]"
check "Deployment script exists" "[ -f 'deploy.sh' ]"
check "Security scan script exists" "[ -f 'security-scan.sh' ]"
check "README documentation exists" "[ -f 'README.md' ]"
check "Fail2ban configuration exists" "[ -f 'fail2ban.conf' ]"
echo

# Check script permissions
echo "🔐 Checking script permissions..."
for script in deploy.sh security-scan.sh docker-entrypoint.prod.sh; do
    if [ -f "$script" ]; then
        if [ -x "$script" ]; then
            check "$script is executable" "true"
        else
            check "$script is executable" "false"
            info "Run: chmod +x $script"
        fi
    fi
done
echo

# Check Docker configuration
echo "🐳 Checking Docker configuration..."
check "Dockerfile uses multi-stage build" "grep -q 'FROM.*AS' Dockerfile.prod"
check "Dockerfile creates non-root user" "grep -q 'adduser.*tailscale' Dockerfile.prod"
check "Dockerfile has health check" "grep -q 'HEALTHCHECK' Dockerfile.prod"
check "Docker-compose has resource limits" "grep -q 'limits:' docker-compose.prod.yml"
check "Docker-compose has health check" "grep -q 'healthcheck:' docker-compose.prod.yml"
echo

# Check security configuration
echo "🛡️  Checking security configuration..."
check "Nginx enforces HTTPS" "grep -q 'return 301 https' nginx.prod.conf"
check "Nginx uses TLS 1.3" "grep -q 'TLSv1.3' nginx.prod.conf"
check "Nginx has security headers" "grep -q 'X-Frame-Options' nginx.prod.conf"
check "Nginx has rate limiting" "grep -q 'limit_req_zone' nginx.prod.conf"
check "Fail2ban is configured" "grep -q 'enabled = true' fail2ban.conf"
check "No hardcoded passwords in supervisord" "! grep -q 'password=change_this_password' supervisord.prod.conf || echo 'WARNING: Change default password!'"
echo

# Check monitoring setup
echo "📊 Checking monitoring setup..."
check "Health endpoint configured" "grep -q '/health' nginx.prod.conf"
check "Status endpoint configured" "grep -q '/status' nginx.prod.conf"
check "Prometheus config exists" "[ -f 'monitoring/prometheus.yml' ]"
check "Structured logging configured" "grep -q 'log_format' nginx.prod.conf"
echo

# Check CI/CD setup
echo "🔄 Checking CI/CD setup..."
check "GitHub workflow exists" "[ -f '.github/workflows/security-and-deploy.yml' ]"
check "Workflow has security scans" "grep -q 'trivy' .github/workflows/security-and-deploy.yml"
check "Workflow has deployment jobs" "grep -q 'deploy-production' .github/workflows/security-and-deploy.yml"
echo

# Check documentation
echo "📚 Checking documentation..."
check "README has quick start guide" "grep -q 'Quick Start' README.md"
check "README has security section" "grep -q 'Security' README.md"
check "README has troubleshooting" "grep -q -i 'troubleshoot' README.md"
check "README has configuration docs" "grep -q 'Configuration' README.md"
echo

# Environment validation
echo "🌍 Checking environment requirements..."
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    if [[ "$TAILSCALE_AUTHKEY" =~ ^tskey-auth-[a-zA-Z0-9_-]+$ ]]; then
        check "TAILSCALE_AUTHKEY format is valid" "true"
    else
        check "TAILSCALE_AUTHKEY format is valid" "false"
    fi
else
    warn "TAILSCALE_AUTHKEY not set (required for deployment)"
fi

check "Docker is available" "command -v docker >/dev/null"
check "Docker Compose is available" "command -v docker-compose >/dev/null"
echo

# Final validation
echo "🔍 Running final checks..."

# Check for common issues
if grep -r "localhost" . --exclude-dir=.git --exclude="validate-setup.sh" | grep -v "127.0.0.1" | grep -q .; then
    warn "Found references to 'localhost' - may cause issues in containerized deployment"
fi

if find . -name "*.log" -o -name "*.tmp" | grep -q .; then
    warn "Temporary files found - clean up before deployment"
fi

if [ -d ".git" ] && git status --porcelain | grep -q .; then
    warn "Uncommitted changes found - commit before deployment"
fi

echo
echo "==========================================="
echo "  VALIDATION SUMMARY"
echo "==========================================="
echo -e "${GREEN}✓ Successful checks: $success${NC}"
if [ $warnings -gt 0 ]; then
    echo -e "${YELLOW}⚠ Warnings: $warnings${NC}"
fi
if [ $errors -gt 0 ]; then
    echo -e "${RED}✗ Errors: $errors${NC}"
fi
echo

if [ $errors -eq 0 ]; then
    if [ $warnings -eq 0 ]; then
        echo -e "${GREEN}🎉 ALL CHECKS PASSED! Ready for production deployment.${NC}"
        echo
        echo "Next steps:"
        echo "1. Set TAILSCALE_AUTHKEY environment variable"
        echo "2. Run: ./deploy.sh"
        echo "3. Verify deployment: curl http://localhost/health"
        exit 0
    else
        echo -e "${YELLOW}✅ VALIDATION PASSED with warnings.${NC}"
        echo -e "${YELLOW}Consider addressing warnings before production deployment.${NC}"
        exit 1
    fi
else
    echo -e "${RED}❌ VALIDATION FAILED.${NC}"
    echo -e "${RED}Fix errors before proceeding with deployment.${NC}"
    exit 2
fi
