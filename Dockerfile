FROM alpine:3.20 AS tailscale-builder
ARG TS_VERSION=1.86.2
RUN apk add --no-cache curl ca-certificates
WORKDIR /tmp
RUN curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_amd64.tgz" | \
    tar -xz --strip-components=1

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tini supervisor python3 ip6tables
COPY --from=tailscale-builder /tmp/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale-builder /tmp/tailscale   /usr/local/bin/tailscale
COPY supervisord.conf /etc/supervisor/conf.d/services.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
RUN mkdir -p /var/run/tailscale /workspace

RUN echo '<!DOCTYPE html><html><head><title>Tailscale Exit Node Status</title></head><body><h1>Tailscale Exit Node is Running</h1><p>This node is active and available as an exit node for your tailnet.</p></body></html>' > /workspace/index.html

WORKDIR /workspace

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD tailscale status || exit 1

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--", "/docker-entrypoint.sh"]
