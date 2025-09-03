#!/bin/sh

#!/bin/sh
set -e

# Flush old rules (optional, non-fatal)
iptables -F INPUT 2>/dev/null || true
ip6tables -F 2>/dev/null || true

# Block all IPv6 traffic (optional, non-fatal)
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true

# Harden IPv4 firewall (optional, non-fatal)
iptables -P INPUT DROP 2>/dev/null || true
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true

# --- Optional: rate limit HTTP to mitigate floods ---
# iptables -A INPUT -p tcp --dport 8080 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT

# --- Environment cleanup ---
unset KUBERNETES_SERVICE_HOST KUBERNETES_PORT KUBERNETES_PORT_443_TCP
# --- Start Supervisor (manages tailscaled, tailscale up, http-server) ---
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/services.conf
