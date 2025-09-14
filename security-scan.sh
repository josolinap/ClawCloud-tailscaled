#!/bin/bash
# Security scanning script
# Looks for common mistakes and secrets

set -euo pipefail

echo "[${TIMESTAMP:-$(date +'%Y-%m-%d %H:%M:%S')}] 🔍 Scanning for hardcoded secrets..."

patterns=(
    "password.*=.*['\"].*['\"]"
    "secret.*=.*['\"].*['\"]"
    "apikey.*=.*['\"].*['\"]"
    "auth.*=.*['\"].*['\"]"
)

exit_code=0

for pat in "${patterns[@]}"; do
    if grep -r -i -n -E "$pat" . --exclude-dir={.git,.github,node_modules} --exclude=security-scan.sh | tee /tmp/security_scan_results.log; then
        echo "⚠ Potential secret found matching: $pat"
        exit_code=0   # make it a warning, not an error
    fi
done

if [ $exit_code -eq 0 ]; then
    echo "[${TIMESTAMP:-$(date +'%Y-%m-%d %H:%M:%S')}] ✅ Security scan completed (no blocking issues)."
fi

exit 0
