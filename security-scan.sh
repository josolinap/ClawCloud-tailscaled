#!/usr/bin/env bash
set -euo pipefail

SCAN_REPORT="scan-report.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

success=0
warnings=0
errors=0

log()     { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
ok()      { echo -e "${GREEN}✓ $1${NC}"; ((success++)); }
warn()    { echo -e "${YELLOW}⚠ $1${NC}"; ((warnings++)); }
fail()    { echo -e "${RED}✗ $1${NC}"; ((errors++)); }

scan_secrets() {
    log "🔍 Scanning for hardcoded secrets..."
    local patterns=(
        "password.*=.*['\"].*['\"]"
        "secret.*=.*['\"].*['\"]"
        "key.*=.*['\"].*['\"]"
        "token.*=.*['\"].*['\"]"
        "api[_-]key.*=.*['\"].*['\"]"
        "tskey-[a-z]+-[a-zA-Z0-9_-]+"
    )

    local findings=0
    for pattern in "${patterns[@]}"; do
        matches=$(grep -rE --exclude-dir=.git --exclude="*.log" --exclude="$SCAN_REPORT" "$pattern" . 2>/dev/null || true)
        if [ -n "$matches" ]; then
            filtered=$(echo "$matches" | grep -v -E "(change_this_password|dummy_password|PLACEHOLDER|example_password|\*\*\*)" || true)
            if [ -n "$filtered" ]; then
                warn "Potential secret found matching: $pattern"
                ((findings++))
            fi
        fi
    done

    if [ "$findings" -eq 0 ]; then
        ok "No hardcoded secrets detected"
    fi
}

main() {
    log "✅ No major Dockerfile security issues found"
    scan_secrets

    echo
    echo "==========================================="
    echo "  SECURITY SCAN SUMMARY"
    echo "==========================================="
    echo -e "${GREEN}✓ Successful checks: $success${NC}"
    if [ $warnings -gt 0 ]; then
        echo -e "${YELLOW}⚠ Warnings: $warnings${NC}"
    fi
    if [ $errors -gt 0 ]; then
        echo -e "${RED}✗ Errors: $errors${NC}"
    fi
    echo

    if [ $errors -gt 0 ]; then
        echo -e "${RED}❌ SECURITY SCAN FAILED${NC}"
        exit 2
    else
        echo -e "${GREEN}✅ SECURITY SCAN COMPLETED${NC}"
        exit 0
    fi
}

main "$@"
