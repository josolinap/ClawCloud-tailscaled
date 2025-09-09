# Tailscale Exit Node - Production Ready for claw.cloud

A production-hardened Tailscale exit node implementation designed for secure deployment on claw.cloud. This solution provides enterprise-grade security, monitoring, and compliance features.

## 🚀 Features

### Security
- **TLS 1.3 Only**: Modern encryption standards
- **Security Headers**: Comprehensive OWASP recommendations
- **Rate Limiting**: DDoS protection and abuse prevention
- **Fail2ban Integration**: Automated intrusion prevention
- **Non-root Execution**: Where possible for reduced attack surface
- **Input Validation**: All environment variables validated
- **Secrets Management**: No hardcoded credentials

### Performance & Scalability
- **Multi-stage Docker Build**: Optimized image size
- **Resource Limits**: CPU and memory constraints
- **Health Checks**: Automated monitoring and recovery
- **Log Rotation**: Prevents disk space issues
- **Graceful Shutdown**: Clean termination handling

### Compliance & Privacy
- **Minimal Logging**: No user data or traffic logged
- **Anonymity Preservation**: No metadata leaks
- **Privacy Headers**: Enhanced user protection
- **Audit Trail**: Deployment and access logging

### Monitoring & Operations
- **Prometheus Metrics**: Comprehensive monitoring
- **Health Endpoints**: Service status checking
- **Structured Logging**: Easy troubleshooting
- **Automated Deployment**: CI/CD ready

## 🛠 Prerequisites

- Docker Engine 20.10+
- Docker Compose 2.0+
- Valid Tailscale auth key
- Linux host with kernel 4.19+ (for optimal networking)
- Minimum 512MB RAM, 1 CPU core

## 📋 Quick Start

### 1. Clone and Setup

```bash
git clone <repository-url>
cd render_tailscaled_kapa-main
chmod +x deploy.sh
```

### 2. Get Tailscale Auth Key

1. Visit [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
2. Generate a new auth key
3. Set it as reusable and with appropriate expiration

### 3. Deploy

```bash
# Basic deployment
TAILSCALE_AUTHKEY=tskey-auth-your-key-here ./deploy.sh

# With custom hostname
HOSTNAME=my-exit-node TAILSCALE_AUTHKEY=tskey-auth-your-key-here ./deploy.sh
```

### 4. Verify Deployment

```bash
# Check status
./deploy.sh --status

# View logs
./deploy.sh --logs

# Test endpoints
curl http://localhost/health
curl https://localhost/status
```

## 🔧 Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TAILSCALE_AUTHKEY` | ✅ | - | Your Tailscale authentication key |
| `HOSTNAME` | ❌ | `tailscale-exit-{timestamp}` | Hostname for the exit node |
| `TZ` | ❌ | `UTC` | Timezone for logging |
| `DISABLE_IPV6` | ❌ | `true` | Disable IPv6 networking |

### SSL Certificates

For production deployment, replace self-signed certificates:

```bash
# Place your certificates
cp your-cert.pem ./ssl/cert.pem
cp your-key.pem ./ssl/key.pem

# Deploy
./deploy.sh
```

### Custom Configuration

Override default configurations by mounting custom files:

```yaml
# docker-compose.override.yml
version: '3.8'
services:
  tailscale-exit-node:
    volumes:
      - ./custom-nginx.conf:/etc/nginx/nginx.conf:ro
```

## 📊 Monitoring

### Built-in Endpoints

- **Health Check**: `GET /health` - Service health status
- **Status**: `GET /status` - Exit node status
- **Metrics**: `GET /metrics` - Prometheus metrics (if enabled)

### Log Files

Logs are stored in `./logs/` directory:

```
logs/
├── nginx/          # Nginx access and error logs
├── tailscale/      # Tailscale daemon logs
└── supervisor/     # Process management logs
```

### Prometheus Monitoring

Enable monitoring stack:

```bash
# Uncomment monitoring services in docker-compose.prod.yml
docker-compose -f docker-compose.prod.yml up -d prometheus grafana
```

Access dashboards:
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000 (admin/admin123)

## 🔐 Security Best Practices

### 1. Network Security

```bash
# Configure firewall (example for UFW)
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP (redirects to HTTPS)
ufw allow 443/tcp   # HTTPS
ufw allow 41641/udp # Tailscale
ufw enable
```

### 2. SSL/TLS Configuration

- Use valid certificates from a trusted CA
- Enable OCSP stapling
- Configure perfect forward secrecy
- Regular certificate rotation

### 3. Access Control

- Restrict Tailscale ACLs to necessary devices
- Use ephemeral auth keys when possible
- Monitor access logs regularly
- Implement IP allowlisting if needed

### 4. System Hardening

```bash
# System-level security
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
echo 'net.ipv4.conf.all.accept_redirects=0' >> /etc/sysctl.conf
sysctl -p

# Keep system updated
apt update && apt upgrade -y
```

## 🚀 Deployment Modes

### Development

```bash
# Use development configuration
docker-compose up -d
```

### Production

```bash
# Use production configuration
./deploy.sh
```

### CI/CD Integration

```yaml
# Example GitHub Actions workflow
name: Deploy Tailscale Exit Node

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Deploy
        env:
          TAILSCALE_AUTHKEY: ${{ secrets.TAILSCALE_AUTHKEY }}
        run: ./deploy.sh
```

## 🔄 Operations

### Updating

```bash
# Pull latest changes
git pull origin main

# Rebuild and deploy
./deploy.sh
```

### Backup

```bash
# Backup Tailscale state
tar -czf backup-$(date +%Y%m%d).tar.gz data/ ssl/
```

### Scaling

For high-traffic scenarios:

1. **Horizontal Scaling**: Deploy multiple exit nodes
2. **Load Balancing**: Use DNS round-robin or load balancer
3. **Resource Scaling**: Increase container limits

### Troubleshooting

#### Common Issues

1. **Container won't start**
   ```bash
   # Check logs
   docker-compose -f docker-compose.prod.yml logs tailscale-exit-node
   
   # Verify auth key
   echo $TAILSCALE_AUTHKEY | grep "tskey-auth-"
   ```

2. **Network connectivity issues**
   ```bash
   # Check IP forwarding
   sysctl net.ipv4.ip_forward
   
   # Verify firewall rules
   iptables -L -n
   ```

3. **SSL certificate problems**
   ```bash
   # Test SSL
   openssl s_client -connect localhost:443
   
   # Check certificate validity
   openssl x509 -in ssl/cert.pem -text -noout
   ```

#### Debug Mode

```bash
# Enable debug logging
docker-compose -f docker-compose.prod.yml down
docker-compose -f docker-compose.prod.yml up
```

## 📚 Architecture

```
┌─────────────────────────────────────────────┐
│                  claw.cloud                 │
├─────────────────────────────────────────────┤
│  ┌─────────────────────────────────────┐    │
│  │           Docker Container          │    │
│  │  ┌─────────────────────────────┐    │    │
│  │  │        Supervisor           │    │    │
│  │  │  ┌─────────┬─────────┬───┐  │    │    │
│  │  │  │ Nginx   │Tailscale│F2B│  │    │    │
│  │  │  │(HTTPS)  │ Daemon  │   │  │    │    │
│  │  │  └─────────┴─────────┴───┘  │    │    │
│  │  └─────────────────────────────┘    │    │
│  └─────────────────────────────────────┘    │
├─────────────────────────────────────────────┤
│         Host Network & Firewall             │
└─────────────────────────────────────────────┘
```

### Components

- **Nginx**: HTTPS termination, security headers, rate limiting
- **Tailscale**: VPN exit node functionality
- **Supervisor**: Process management and monitoring
- **Fail2ban**: Intrusion prevention system
- **Docker**: Containerization and isolation

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Run security tests: `./deploy.sh --dry-run`
4. Submit a pull request

## 📄 License

MIT License - see LICENSE file for details

## 🆘 Support

For issues and questions:

1. Check the troubleshooting section
2. Review logs: `./deploy.sh --logs`
3. Create an issue with logs and configuration

## 🔗 Related Links

- [Tailscale Documentation](https://tailscale.com/docs/)
- [claw.cloud Platform](https://claw.cloud/)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
- [Nginx Security](https://nginx.org/en/docs/http/ngx_http_ssl_module.html)
