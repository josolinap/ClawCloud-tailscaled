#!/bin/bash
# Bandwidth monitoring script for claw.cloud 35GB monthly limit prevention
# Monitors network usage and throttles connections before hitting speed limits

set -euo pipefail

# Configuration
BANDWIDTH_DIR="/var/lib/tailscale/bandwidth"
USAGE_FILE="$BANDWIDTH_DIR/monthly_usage"
MONTH_FILE="$BANDWIDTH_DIR/current_month"
LOG_FILE="/var/log/tailscale/bandwidth.log"
LIMIT_GB=35
WARNING_GB=30
THROTTLE_GB=32

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - BANDWIDTH: $1" | tee -a "$LOG_FILE"
}

# Function to get current network usage in bytes
get_network_usage() {
    local rx_bytes=0
    local tx_bytes=0
    
    # Sum up all network interfaces except loopback
    for interface in /sys/class/net/*/statistics; do
        local iface_name=$(basename $(dirname "$interface"))
        if [ "$iface_name" != "lo" ]; then
            local rx=$(cat "$interface/rx_bytes" 2>/dev/null || echo 0)
            local tx=$(cat "$interface/tx_bytes" 2>/dev/null || echo 0)
            rx_bytes=$((rx_bytes + rx))
            tx_bytes=$((tx_bytes + tx))
        fi
    done
    
    echo $((rx_bytes + tx_bytes))
}

# Function to convert bytes to GB
bytes_to_gb() {
    echo "scale=2; $1 / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0"
}

# Function to check if it's a new month
check_month_rollover() {
    local current_month=$(date +%Y-%m)
    local stored_month=""
    
    if [ -f "$MONTH_FILE" ]; then
        stored_month=$(cat "$MONTH_FILE")
    fi
    
    if [ "$current_month" != "$stored_month" ]; then
        log "Month rollover detected: $stored_month -> $current_month"
        echo "0" > "$USAGE_FILE"
        echo "$current_month" > "$MONTH_FILE"
        # Reset any throttling
        remove_throttling
        return 0
    fi
    return 1
}

# Function to apply bandwidth throttling
apply_throttling() {
    local limit_kbps=$1
    log "Applying bandwidth throttling: ${limit_kbps}kbps"
    
    # Use tc (traffic control) to limit bandwidth if available
    if command -v tc >/dev/null 2>&1; then
        # Create qdisc for limiting
        tc qdisc add dev eth0 root handle 1: tbf rate ${limit_kbps}kbit burst 32kbit latency 400ms 2>/dev/null || true
        log "Applied tc throttling"
    fi
    
    # Alternative: Use iptables rate limiting
    if command -v iptables >/dev/null 2>&1; then
        iptables -A OUTPUT -m limit --limit 50/sec --limit-burst 100 -j ACCEPT 2>/dev/null || true
        log "Applied iptables rate limiting"
    fi
    
    # Set environment variable for application-level throttling
    export BANDWIDTH_THROTTLED=true
}

# Function to remove bandwidth throttling
remove_throttling() {
    log "Removing bandwidth throttling"
    
    # Remove tc qdisc
    tc qdisc del dev eth0 root 2>/dev/null || true
    
    # Remove iptables rules
    iptables -D OUTPUT -m limit --limit 50/sec --limit-burst 100 -j ACCEPT 2>/dev/null || true
    
    unset BANDWIDTH_THROTTLED
}

# Function to create status.json for nginx endpoint
create_status_json() {
    local total_usage_gb="$1"
    local current_usage_gb="$2"
    local timestamp=$(date -Iseconds)
    local status="normal"
    
    # Determine status based on usage
    local usage_int=$(echo "$total_usage_gb" | cut -d. -f1)
    if [ "$usage_int" -ge "$LIMIT_GB" ]; then
        status="limit_exceeded"
    elif [ "$usage_int" -ge "$THROTTLE_GB" ]; then
        status="throttled"
    elif [ "$usage_int" -ge "$WARNING_GB" ]; then
        status="warning"
    fi
    
    # Create status JSON file for nginx
    mkdir -p "$(dirname "$BANDWIDTH_DIR/status.json")"
    cat > "$BANDWIDTH_DIR/status.json" << EOF
{
    "status": "$status",
    "timestamp": "$timestamp",
    "usage": {
        "current_session_gb": $current_usage_gb,
        "monthly_total_gb": $total_usage_gb,
        "limit_gb": $LIMIT_GB,
        "warning_threshold_gb": $WARNING_GB,
        "throttle_threshold_gb": $THROTTLE_GB
    },
    "thresholds": {
        "warning_reached": $([ "$usage_int" -ge "$WARNING_GB" ] && echo "true" || echo "false"),
        "throttle_active": $([ "$usage_int" -ge "$THROTTLE_GB" ] && echo "true" || echo "false"),
        "limit_exceeded": $([ "$usage_int" -ge "$LIMIT_GB" ] && echo "true" || echo "false")
    }
}
EOF
}

# Function to update usage and check limits
update_and_check_usage() {
    local current_usage_bytes
    local current_usage_gb
    local stored_usage_gb
    
    current_usage_bytes=$(get_network_usage)
    current_usage_gb=$(bytes_to_gb $current_usage_bytes)
    
    # Read stored usage
    if [ -f "$USAGE_FILE" ]; then
        stored_usage_gb=$(cat "$USAGE_FILE")
    else
        stored_usage_gb="0"
    fi
    
    # Calculate total usage (stored + current session)
    local total_usage_gb=$(echo "scale=2; $stored_usage_gb + $current_usage_gb" | bc -l)
    
    log "Current session: ${current_usage_gb}GB, Total monthly: ${total_usage_gb}GB"
    
    # Create status.json for nginx status endpoint
    create_status_json "$total_usage_gb" "$current_usage_gb"
    
    # Check thresholds
    local usage_int=$(echo "$total_usage_gb" | cut -d. -f1)
    
    if [ "$usage_int" -ge "$LIMIT_GB" ]; then
        log "CRITICAL: Monthly bandwidth limit exceeded (${total_usage_gb}GB/${LIMIT_GB}GB)"
        log "Stopping Tailscale to prevent further charges"
        pkill tailscaled 2>/dev/null || true
        
    elif [ "$usage_int" -ge "$THROTTLE_GB" ]; then
        log "WARNING: Throttling threshold reached (${total_usage_gb}GB/${THROTTLE_GB}GB)"
        apply_throttling 128  # 128kbps throttling
        
    elif [ "$usage_int" -ge "$WARNING_GB" ]; then
        log "WARNING: Approaching bandwidth limit (${total_usage_gb}GB/${LIMIT_GB}GB)"
        apply_throttling 512  # 512kbps throttling
        
    else
        # Remove throttling if usage is back to normal
        if [ -n "${BANDWIDTH_THROTTLED:-}" ]; then
            remove_throttling
        fi
    fi
    
    # Update stored usage every hour
    local current_hour=$(date +%H)
    local last_update_file="$BANDWIDTH_DIR/last_update_hour"
    local last_hour=""
    
    if [ -f "$last_update_file" ]; then
        last_hour=$(cat "$last_update_file")
    fi
    
    if [ "$current_hour" != "$last_hour" ]; then
        echo "$total_usage_gb" > "$USAGE_FILE"
        echo "$current_hour" > "$last_update_file"
        log "Updated stored usage: ${total_usage_gb}GB"
    fi
}

# Note: Status JSON is created by create_status_json function called from update_and_check_usage

# Main monitoring loop
main() {
    log "Starting bandwidth monitoring for claw.cloud"
    log "Monthly limit: ${LIMIT_GB}GB, Warning: ${WARNING_GB}GB, Throttle: ${THROTTLE_GB}GB"
    
    # Ensure directories exist
    mkdir -p "$BANDWIDTH_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Initialize files if they don't exist
    [ -f "$USAGE_FILE" ] || echo "0" > "$USAGE_FILE"
    [ -f "$MONTH_FILE" ] || echo "$(date +%Y-%m)" > "$MONTH_FILE"
    
    while true; do
        # Check for month rollover
        check_month_rollover
        
        # Update usage and check limits
        update_and_check_usage
        
        # Create status report
        # Status report is created by update_and_check_usage
        
        # Sleep for 60 seconds before next check
        sleep 60
    done
}

# Handle signals
trap 'log "Bandwidth monitor stopping"; remove_throttling; exit 0' EXIT INT TERM

# Install bc if not available (for floating point math)
if ! command -v bc >/dev/null 2>&1; then
    log "Installing bc for bandwidth calculations"
    apk add --no-cache bc 2>/dev/null || true
fi

# Run main function
main
