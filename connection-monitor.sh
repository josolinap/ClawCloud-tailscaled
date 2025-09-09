#!/bin/bash
# Self-healing connection monitor for Tailscale
# Automatically detects and fixes connection issues

set -euo pipefail

MONITOR_LOG="/var/log/tailscale/connection-monitor.log"
CHECK_INTERVAL=30
FAILURE_THRESHOLD=3
RECONNECT_THRESHOLD=5

# Connection state tracking
consecutive_failures=0
last_successful_check=0
total_reconnects=0

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$MONITOR_LOG"
}

# Check if Tailscale daemon is running
check_tailscaled() {
    if pgrep -f tailscaled >/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check Tailscale connection status
check_tailscale_status() {
    local status_output
    if status_output=$(tailscale status --json 2>/dev/null); then
        local backend_state=$(echo "$status_output" | jq -r '.BackendState // "Unknown"')
        case "$backend_state" in
            "Running")
                return 0
                ;;
            "Starting"|"NeedsLogin")
                return 1
                ;;
            *)
                return 2
                ;;
        esac
    else
        return 3
    fi
}

# Test actual connectivity through Tailscale
test_tailscale_connectivity() {
    local test_methods=0
    local successful_tests=0
    
    # Method 1: Test tailscale status command
    if tailscale status >/dev/null 2>&1; then
        ((successful_tests++))
    fi
    ((test_methods++))
    
    # Method 2: Test ping to Tailscale coordination server
    if timeout 5 ping -c 1 login.tailscale.com >/dev/null 2>&1; then
        ((successful_tests++))
    fi
    ((test_methods++))
    
    # Method 3: Test netcheck
    if tailscale netcheck --verbose 2>/dev/null | grep -q "UDP:.*true"; then
        ((successful_tests++))
    fi
    ((test_methods++))
    
    # Method 4: Test if we can reach other tailnet nodes (if any)
    local peers
    if peers=$(tailscale status --json 2>/dev/null | jq -r '.Peer | keys[]' 2>/dev/null); then
        if [ -n "$peers" ]; then
            local peer_reachable=false
            while read -r peer_ip; do
                if [ -n "$peer_ip" ] && timeout 3 ping -c 1 "$peer_ip" >/dev/null 2>&1; then
                    peer_reachable=true
                    break
                fi
            done < <(echo "$peers")
            
            if $peer_reachable; then
                ((successful_tests++))
            fi
            ((test_methods++))
        fi
    fi
    
    # Return success if at least half the tests pass
    local required_success=$((test_methods / 2))
    [ $successful_tests -ge $required_success ]
}

# Test exit node functionality specifically
test_exit_node_functionality() {
    local exit_node_status
    if exit_node_status=$(tailscale status --json 2>/dev/null | jq -r '.ExitNodeStatus // "none"'); then
        case "$exit_node_status" in
            "online"|"active")
                return 0
                ;;
            *)
                return 1
                ;;
        esac
    else
        return 1
    fi
}

# Intelligent reconnection strategy
intelligent_reconnect() {
    log "Starting intelligent reconnection process..."
    
    local reconnect_methods=(
        "soft_restart"
        "auth_refresh" 
        "hard_restart"
        "full_reset"
    )
    
    for method in "${reconnect_methods[@]}"; do
        log "Trying reconnection method: $method"
        
        case "$method" in
            "soft_restart")
                # Try graceful restart of tailscale connection
                if tailscale down 2>/dev/null && sleep 5 && tailscale up --authkey="${TAILSCALE_AUTHKEY}" --advertise-exit-node --accept-routes --accept-dns=false --netfilter-mode=on 2>/dev/null; then
                    log "Soft restart successful"
                    return 0
                fi
                ;;
            
            "auth_refresh")
                # Try refreshing auth without full restart
                if tailscale up --authkey="${TAILSCALE_AUTHKEY}" --reset 2>/dev/null; then
                    log "Auth refresh successful" 
                    return 0
                fi
                ;;
                
            "hard_restart")
                # Restart tailscaled daemon
                if command -v supervisorctl >/dev/null 2>&1; then
                    supervisorctl restart tailscaled
                    sleep 10
                    if tailscale up --authkey="${TAILSCALE_AUTHKEY}" --advertise-exit-node --accept-routes --accept-dns=false --netfilter-mode=on 2>/dev/null; then
                        log "Hard restart successful"
                        return 0
                    fi
                fi
                ;;
                
            "full_reset")
                # Full reset - remove state and restart everything
                log "Performing full reset - this may take longer..."
                
                # Stop tailscale
                tailscale down 2>/dev/null || true
                
                # Stop daemon
                if command -v supervisorctl >/dev/null 2>&1; then
                    supervisorctl stop tailscaled
                fi
                
                # Remove state files
                rm -f /var/lib/tailscale/tailscaled.state*
                
                # Restart daemon
                if command -v supervisorctl >/dev/null 2>&1; then
                    supervisorctl start tailscaled
                    sleep 15
                fi
                
                # Reconnect
                if tailscale up --authkey="${TAILSCALE_AUTHKEY}" --advertise-exit-node --accept-routes --accept-dns=false --netfilter-mode=on --reset 2>/dev/null; then
                    log "Full reset successful"
                    return 0
                fi
                ;;
        esac
        
        # Wait between attempts
        sleep 10
    done
    
    log "All reconnection methods failed"
    return 1
}

# Health check with self-healing
perform_health_check() {
    local health_issues=()
    
    # Check 1: Daemon running
    if ! check_tailscaled; then
        health_issues+=("tailscaled not running")
    fi
    
    # Check 2: Connection status
    local status_code
    check_tailscale_status
    status_code=$?
    case $status_code in
        1) health_issues+=("tailscale needs login") ;;
        2) health_issues+=("tailscale in unknown state") ;;
        3) health_issues+=("cannot get tailscale status") ;;
    esac
    
    # Check 3: Actual connectivity
    if ! test_tailscale_connectivity; then
        health_issues+=("tailscale connectivity failed")
    fi
    
    # Check 4: Exit node functionality
    if ! test_exit_node_functionality; then
        health_issues+=("exit node not functioning")
    fi
    
    # Check 5: DNS resolution
    if ! nslookup google.com >/dev/null 2>&1; then
        health_issues+=("DNS resolution failed")
    fi
    
    # Check 6: Internet connectivity through exit node
    if ! timeout 10 curl -s --max-time 5 http://www.google.com >/dev/null; then
        health_issues+=("internet connectivity through exit node failed")
    fi
    
    if [ ${#health_issues[@]} -eq 0 ]; then
        return 0  # All healthy
    else
        log "Health issues detected: ${health_issues[*]}"
        return 1  # Issues found
    fi
}

# Advanced diagnostics
run_diagnostics() {
    log "Running advanced diagnostics..."
    
    echo "=== Tailscale Diagnostics Report ===" | tee -a "$MONITOR_LOG"
    
    # Basic info
    log "Tailscale version: $(tailscale version 2>/dev/null || echo 'Unknown')"
    log "Container hostname: $(hostname)"
    log "Container IP: $(hostname -I | awk '{print $1}')"
    
    # Process info
    log "Tailscaled process:"
    ps aux | grep tailscaled | grep -v grep | tee -a "$MONITOR_LOG"
    
    # Network interfaces
    log "Network interfaces:"
    ip addr show | grep -E "(tailscale|eth|en)" | tee -a "$MONITOR_LOG"
    
    # Tailscale status
    log "Tailscale status:"
    tailscale status 2>&1 | tee -a "$MONITOR_LOG"
    
    # Network check
    log "Tailscale netcheck:"
    tailscale netcheck 2>&1 | tee -a "$MONITOR_LOG"
    
    # DNS info
    log "DNS configuration:"
    cat /etc/resolv.conf | tee -a "$MONITOR_LOG"
    
    # Routes
    log "IP routes:"
    ip route show | head -20 | tee -a "$MONITOR_LOG"
    
    # iptables (sample)
    log "iptables rules (sample):"
    iptables -L -n | head -20 | tee -a "$MONITOR_LOG"
    
    log "Diagnostics complete"
}

# Main monitoring loop
monitor_loop() {
    log "Starting Tailscale connection monitor..."
    log "Check interval: ${CHECK_INTERVAL}s, Failure threshold: $FAILURE_THRESHOLD"
    
    while true; do
        local current_time=$(date +%s)
        
        if perform_health_check; then
            # Health check passed
            if [ $consecutive_failures -gt 0 ]; then
                log "Connection restored after $consecutive_failures failures"
            fi
            consecutive_failures=0
            last_successful_check=$current_time
        else
            # Health check failed
            ((consecutive_failures++))
            log "Health check failed ($consecutive_failures/$FAILURE_THRESHOLD)"
            
            if [ $consecutive_failures -ge $FAILURE_THRESHOLD ]; then
                log "Failure threshold reached, attempting reconnection..."
                
                # Run diagnostics before attempting fix
                run_diagnostics
                
                # Attempt intelligent reconnection
                if intelligent_reconnect; then
                    log "Reconnection successful"
                    consecutive_failures=0
                    ((total_reconnects++))
                    last_successful_check=$current_time
                else
                    log "Reconnection failed, will retry in next cycle"
                    
                    # If we've been failing for too long, try more aggressive fixes
                    local time_since_success=$((current_time - last_successful_check))
                    if [ $time_since_success -gt 300 ]; then  # 5 minutes
                        log "Long-term failure detected, running network fixes..."
                        
                        # Run iptables fixes
                        if [ -x ./iptables-manager.sh ]; then
                            ./iptables-manager.sh fix
                        fi
                        
                        # Run DNS fixes
                        if [ -x ./dns-manager.sh ]; then
                            ./dns-manager.sh fix
                        fi
                    fi
                fi
            fi
        fi
        
        # Log periodic status
        if [ $((current_time % 300)) -eq 0 ]; then  # Every 5 minutes
            log "Status: Failures=$consecutive_failures, Total reconnects=$total_reconnects, Last success=$(date -d "@$last_successful_check" '+%H:%M:%S')"
        fi
        
        sleep $CHECK_INTERVAL
    done
}

# Signal handlers for graceful shutdown
cleanup() {
    log "Connection monitor shutting down..."
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# Main function
main() {
    case "${1:-monitor}" in
        "test")
            log "Running connection test..."
            if perform_health_check; then
                log "✅ All connection tests passed"
                exit 0
            else
                log "❌ Connection tests failed"
                exit 1
            fi
            ;;
        "reconnect")
            log "Manual reconnection requested..."
            if intelligent_reconnect; then
                log "✅ Reconnection successful"
            else
                log "❌ Reconnection failed"
                exit 1
            fi
            ;;
        "diagnostics")
            run_diagnostics
            ;;
        "monitor")
            monitor_loop
            ;;
        *)
            echo "Usage: $0 {test|reconnect|diagnostics|monitor}"
            echo "  test        - Run connection tests"
            echo "  reconnect   - Manual reconnection attempt" 
            echo "  diagnostics - Run advanced diagnostics"
            echo "  monitor     - Start continuous monitoring (default)"
            exit 1
            ;;
    esac
}

main "$@"
