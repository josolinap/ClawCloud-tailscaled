#!/bin/bash
# Enhanced health check script with exponential retry logic
# Designed for robust container health monitoring on claw.cloud

set -euo pipefail

# Configuration
MAX_RETRIES=5
INITIAL_DELAY=1
MAX_DELAY=30
LOG_FILE="/var/log/tailscale/health.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - HEALTH: $1" | tee -a "$LOG_FILE"
}

# Function to check nginx status
check_nginx() {
    local url="http://localhost/health"
    
    if curl -f -s --max-time 5 "$url" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to check Tailscale status
check_tailscale() {
    # Check if tailscaled is running
    if ! pgrep tailscaled >/dev/null; then
        return 1
    fi
    
    # Check if Tailscale socket is responsive
    if [ -S "${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}" ]; then
        # Try to get status (with timeout)
        timeout 5 tailscale --socket="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}" status --json >/dev/null 2>&1
        return $?
    else
        return 1
    fi
}

# Function to check bandwidth monitor
check_bandwidth_monitor() {
    if pgrep -f bandwidth-monitor.sh >/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to check system resources
check_resources() {
    # Check available memory (should have at least 50MB free)
    local mem_available=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$mem_available" -lt 50 ]; then
        log "WARNING: Low memory available: ${mem_available}MB"
    fi
    
    # Check disk space (should have at least 100MB free)
    local disk_available=$(df / | awk 'NR==2 {print int($4/1024)}' 2>/dev/null || echo 0)
    if [ "$disk_available" -lt 100 ]; then
        log "WARNING: Low disk space available: ${disk_available}MB"
    fi
    
    return 0
}

# Function to perform comprehensive health check
health_check() {
    local nginx_ok=false
    local tailscale_ok=false
    local bandwidth_ok=false
    local resources_ok=false
    
    # Check nginx
    if check_nginx; then
        nginx_ok=true
    fi
    
    # Check Tailscale
    if check_tailscale; then
        tailscale_ok=true
    fi
    
    # Check bandwidth monitor
    if check_bandwidth_monitor; then
        bandwidth_ok=true
    fi
    
    # Check resources
    if check_resources; then
        resources_ok=true
    fi
    
    # Evaluate overall health
    if [ "$nginx_ok" = true ] && [ "$tailscale_ok" = true ]; then
        log "Health check PASSED - Core services OK"
        
        # Log warnings for non-critical services
        if [ "$bandwidth_ok" = false ]; then
            log "WARNING: Bandwidth monitor not running"
        fi
        
        return 0
    else
        log "Health check FAILED - nginx: $nginx_ok, tailscale: $tailscale_ok"
        return 1
    fi
}

# Function with exponential backoff retry logic
retry_with_backoff() {
    local attempt=1
    local delay=$INITIAL_DELAY
    
    while [ $attempt -le $MAX_RETRIES ]; do
        log "Health check attempt $attempt/$MAX_RETRIES"
        
        if health_check; then
            log "Health check successful on attempt $attempt"
            return 0
        fi
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            log "Health check failed, retrying in ${delay}s..."
            sleep $delay
            
            # Exponential backoff: double delay each time, cap at MAX_DELAY
            delay=$((delay * 2))
            if [ $delay -gt $MAX_DELAY ]; then
                delay=$MAX_DELAY
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    log "Health check FAILED after $MAX_RETRIES attempts"
    return 1
}

# Function to create health status report
create_health_report() {
    local status="unknown"
    local timestamp=$(date -Iseconds)
    
    if health_check >/dev/null 2>&1; then
        status="healthy"
    else
        status="unhealthy"
    fi
    
    # Create status JSON
    cat > /tmp/health-status.json << EOF
{
    "status": "$status",
    "timestamp": "$timestamp",
    "components": {
        "nginx": $(check_nginx && echo "true" || echo "false"),
        "tailscale": $(check_tailscale && echo "true" || echo "false"),
        "bandwidth_monitor": $(check_bandwidth_monitor && echo "true" || echo "false")
    },
    "resources": {
        "memory_available_mb": $(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0),
        "disk_available_mb": $(df / | awk 'NR==2 {print int($4/1024)}' 2>/dev/null || echo 0)
    }
}
EOF
}

# Main execution
main() {
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Create health status report
    create_health_report
    
    # Perform health check with retry logic
    if retry_with_backoff; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main