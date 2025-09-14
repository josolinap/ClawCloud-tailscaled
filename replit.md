# Overview

This project is a production-ready Tailscale exit node implementation designed for secure deployment on claw.cloud. The system provides a containerized Tailscale exit node with enterprise-grade security features, performance optimizations, and compliance capabilities. The architecture is specifically optimized for free-tier cloud hosting with IPv6 bypass mechanisms and resource constraints.

# User Preferences

Preferred communication style: Simple, everyday language.

# System Architecture

## Container Architecture
The application uses a multi-stage Docker build approach with Alpine Linux as the base image to minimize attack surface and resource usage. The system implements non-root execution where possible and includes comprehensive health checks for automated recovery.

## Network Configuration
The exit node is configured with IPv6 disabled through multiple bypass mechanisms to ensure compatibility with claw.cloud's free tier limitations. It operates in userspace mode as a fallback to handle networking restrictions common in containerized cloud environments.

## Security Framework
The system implements TLS 1.3-only encryption with comprehensive OWASP security headers including HSTS, CSP, and X-Frame-Options. Rate limiting and DDoS protection are built-in, along with Fail2ban integration for automated intrusion prevention. All environment variables undergo input validation, and the system supports external secrets management without hardcoded credentials.

## Performance Optimizations
Resource limits are enforced at the container level (0.1-0.5 CPU, 256-512MB RAM) to prevent resource exhaustion on free-tier hosting. The system includes HTTP/2 support, gzip compression, and optimized connection pooling through Nginx configuration.

## Monitoring and Operations
The architecture includes Prometheus metrics integration for comprehensive monitoring, structured logging for troubleshooting, and automated deployment capabilities. Health endpoints provide service status checking, and the system implements graceful shutdown handling.

## Data Management
The system maintains minimal logging with no user data or traffic logged to preserve privacy and anonymity. Bandwidth monitoring tracks usage against a 35GB monthly limit with automatic throttling capabilities.

# External Dependencies

## Core Services
- **Tailscale**: Primary VPN service requiring authentication keys from Tailscale Admin Console
- **Docker Engine 20.10+**: Container runtime environment
- **Docker Compose 2.0+**: Container orchestration

## Cloud Platform
- **claw.cloud**: Target deployment platform with free-tier optimizations

## Security and Monitoring
- **Fail2ban**: Automated intrusion prevention system
- **Prometheus**: Metrics collection and monitoring
- **SSL/TLS**: Certificate management for HTTPS endpoints

## System Requirements
- Linux host with kernel 4.19+ for optimal networking performance
- Minimum 512MB RAM and 1 CPU core for stable operation