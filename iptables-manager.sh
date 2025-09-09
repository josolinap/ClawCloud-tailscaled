#!/bin/bash
# Intelligent iptables management for Tailscale exit node
# Automatically detects and fixes problematic rules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/tailscale/iptables-manager.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Backup current iptables rules
backup_iptables() {
    log "Backing up current iptables rules..."
    iptables-save > /var/lib/tailscale/iptables.backup.$(date +%s)
    ip6tables-save > /var/lib/tailscale/ip6tables.backup.$(date +%s) 2>/dev/null || true
}

# Test internet connectivity
test_connectivity() {
    local test_urls=("8.8.8.8" "1.1.1.1" "google.com" "tailscale.com")
    local failed=0
    
    for url in "${test_urls[@]}"; do
        if ! timeout 5 ping -c 1 "$url" >/dev/null 2>&1;
 then
            ((failed++))
        fi
    done
    
    return $failed
}

# Detect problematic Tailscale rules
detect_problematic_rules() {
    log "Detecting problematic iptables rules..."
    
    # Common problematic patterns in Tailscale rules
    local problematic_rules=()
    
    # Check for rules that block outgoing traffic
    while read -r line; do
        if [[ "$line" =~ DROP.*--dport.*80|443 ]] || 
           [[ "$line" =~ REJECT.*destination-unreachable ]] ||
           [[ "$line" =~ DROP.*tailscale ]]; then
            problematic_rules+=("$line")
        fi
    done < <(iptables -L -n --line-numbers)
    
    if [ ${#problematic_rules[@]} -gt 0 ]; then
        log "Found ${#problematic_rules[@]} problematic rules"
        printf '%s\n' "${problematic_rules[@]}" | tee -a "$LOG_FILE"
        return 0
    else
        log "No obviously problematic rules found"
        return 1
    fi
}

# Smart rule cleanup - removes specific problematic rules
smart_cleanup() {
    log "Performing smart iptables cleanup..."
    
    # Save current state
    backup_iptables
    
    # Remove specific problematic rules by pattern, not line number
    # This is more reliable than deleting by line number
    
    # Remove DROP rules for common ports that might block exit node traffic
    iptables -D INPUT -p tcp --dport 80 -j DROP 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || true
    
    # Remove overly restrictive FORWARD rules
    iptables -D FORWARD -i tailscale+ -j DROP 2>/dev/null || true
    iptables -D FORWARD -o tailscale+ -j DROP 2>/dev/null || true
    
    # Ensure basic connectivity rules exist
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    
    # Ensure Tailscale interface has proper forwarding
    iptables -A FORWARD -i tailscale+ -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -o tailscale+ -j ACCEPT 2>/dev/null || true
    
    log "Smart cleanup completed"
}

# Create persistent iptables rules for Tailscale exit node
setup_persistent_rules() {
    log "Setting up persistent iptables rules for exit node..."
    
    # Create iptables rules that survive reboots
    cat > /etc/iptables/rules.v4.tailscale << 'EOF'
# Tailscale exit node iptables rules
# These rules ensure proper traffic forwarding for exit node functionality

# Allow loopback
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# Allow established connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow Tailscale interface traffic
-A INPUT -i tailscale+ -j ACCEPT
-A OUTPUT -o tailscale+ -j ACCEPT
-A FORWARD -i tailscale+ -j ACCEPT  
-A FORWARD -o tailscale+ -j ACCEPT

# Allow Tailscale UDP port
-A INPUT -p udp --dport 41641 -j ACCEPT

# Allow HTTP/HTTPS for health checks and management
-A INPUT -p tcp --dport 80 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT

# NAT for exit node functionality
-t nat -A POSTROUTING -o eth+ -j MASQUERADE
-t nat -A POSTROUTING -o en+ -j MASQUERADE
-t nat -A POSTROUTING -o wl+ -j MASQUERADE

# DNS forwarding
-A FORWARD -p udp --dport 53 -j ACCEPT
-A FORWARD -p tcp --dport 53 -j ACCEPT
EOF

    # Apply persistent rules
    if command -v iptables-persistent >/dev/null; then
        iptables-restore < /etc/iptables/rules.v4.tailscale
        log "Persistent rules applied via iptables-persistent"
    else
        log "iptables-persistent not available, rules applied temporarily"
    fi
}

# Monitor and auto-fix iptables issues
monitor_and_fix() {
    log "Starting iptables monitoring and auto-fix..."
    
    local check_interval=30
    local consecutive_failures=0
    local max_failures=3
    
    while true; do
        if ! test_connectivity; then
            ((consecutive_failures++))
            log "Connectivity test failed ($consecutive_failures/$max_failures)"
            
            if [ $consecutive_failures -ge $max_failures ]; then
                log "Maximum failures reached, attempting auto-fix..."
                
                # Try smart cleanup first
                smart_cleanup
                sleep 10
                
                # If still failing, try more aggressive fixes
                if ! test_connectivity; then
                    log "Smart cleanup failed, trying aggressive fix..."
                    
                    # Flush and rebuild essential rules
                    iptables -F INPUT
                    iptables -F OUTPUT  
                    iptables -F FORWARD
                    iptables -t nat -F POSTROUTING
                    
                    # Rebuild basic rules
                    setup_persistent_rules
                    
                    # Restart Tailscale to rebuild its rules
                    systemctl restart tailscaled 2>/dev/null || supervisorctl restart tailscaled
                fi
                
                consecutive_failures=0
            fi
        else
            if [ $consecutive_failures -gt 0 ]; then
                log "Connectivity restored after $consecutive_failures failures"
            fi
            consecutive_failures=0
        fi
        
        sleep $check_interval
    done
}

# Main function
main() {
    case "${1:-monitor}" in
        "backup")
            backup_iptables
            ;;
        "detect")
            detect_problematic_rules
            ;;
        "cleanup")
            smart_cleanup
            ;;
        "setup")
            setup_persistent_rules
            ;;
        "monitor")
            monitor_and_fix
            ;;
        "fix")
            log "Performing immediate fix..."
            backup_iptables
            smart_cleanup
            setup_persistent_rules
            if test_connectivity; then
                log "Fix completed successfully"
            else
                log "Fix completed but connectivity issues may persist"
            fi
            ;;
        *)
            echo "Usage: $0 {backup|detect|cleanup|setup|monitor|fix}"
            echo "  backup  - Backup current iptables rules"
            echo "  detect  - Detect problematic rules"
            echo "  cleanup - Smart cleanup of problematic rules"
            echo "  setup   - Setup persistent rules for exit node"
            echo "  monitor - Continuously monitor and auto-fix (default)"
            echo "  fix     - Immediate fix attempt"
            exit 1
            ;;
    esac
}

main "$@"
