#!/bin/sh

# Allow HTTP server port
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT

# Optional: avoid dropping Tailscale traffic in ephemeral/cloud environments
# iptables -A INPUT -p tcp --syn -j DROP   # Commented to prevent blocking Tailscale

unset KUBERNETES_SERVICE_HOST KUBERNETES_PORT KUBERNETES_PORT_443_TCP
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/services.conf
