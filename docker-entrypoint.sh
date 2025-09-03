#!/bin/sh
set -e

# Flush old rules (optional, non-fatal)
iptables -F INPUT 2>/dev/null || true
iptables -F OUTPUT 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
ip6tables -F 2>/dev/null || true

# Block all IPv6 traffic (optional, non-fatal)
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true

# Harden IPv4 firewall
iptables -P INPUT DROP 2>/dev/null || true
iptables -P FORWARD DROP 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true   # ✅ always allow outbound traffic

# Allow established and related traffic
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

# Allow HTTP service (8080)
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true

# Allow SSH for remote management (optional but recommended)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true

# Allow Tailscale UDP (WireGuard peer traffic)
iptables -A INPUT -p udp --dport 41641 -j ACCEPT 2>/dev/null || true

# Enable forwarding + NAT (only works if TUN mode is available)
iptables -A FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || true
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true

# --- Optional: rate limit HTTP to mitigate floods ---
# iptables -A INPUT -p tcp --dport 8080 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT

# --- Environment cleanup ---
unset KUBERNETES_SERVICE_HOST KUBERNETES_PORT KUBERNETES_PORT_443_TCP

# Start Supervisor (manages tailscaled, tailscale up, http-server)
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/services.conf
