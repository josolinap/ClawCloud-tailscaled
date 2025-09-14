# Use an official Tailscale base image
FROM tailscale/tailscale

# Set the working directory
WORKDIR /app

# Copy the supervisord configuration file
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Install Supervisor
RUN apt-get update && apt-get install -y supervisor


# Install a lightweight web server (e.g., nginx)
RUN apt-get update && apt-get install -y nginx

# Configure nginx to serve a basic response
RUN echo 'server {' > /etc/nginx/sites-available/default && \
    echo '    listen 80;' >> /etc/nginx/sites-available/default && \
    echo '    server_name _;' >> /etc/nginx/sites-available/default && \
    echo '    location / {' >> /etc/nginx/sites-available/default && \
    echo '        return 200 "Tailscale Exit Node is running";' >> /etc/nginx/sites-available/default && \
    echo '    }' >> /etc/nginx/sites-available/default && \
    echo '}' >> /etc/nginx/sites-available/default

# Expose necessary ports
EXPOSE 80 443

# Configure IPv4-only networking
RUN sysctl -w net.ipv6.conf.all.disable_ipv6=1 && \
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 && \
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1

# Start Supervisor and Tailscale
CMD ["/usr/bin/supervisord", "-n"]
