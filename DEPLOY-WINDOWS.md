# Windows Deployment Guide

This guide helps you deploy the Tailscale Exit Node on Windows using Docker Desktop or WSL2.

## Prerequisites

### Option 1: Docker Desktop (Recommended)
1. **Install Docker Desktop**: Download from [docker.com](https://www.docker.com/products/docker-desktop/)
2. **Enable Linux containers** (default setting)
3. **Ensure Docker is running** (Docker whale icon in system tray)

### Option 2: WSL2 + Docker
1. **Install WSL2**: Follow [Microsoft's WSL2 guide](https://docs.microsoft.com/en-us/windows/wsl/install)
2. **Install Docker in WSL2**: Follow Docker's WSL2 backend guide

## Quick Start

### 1. Open PowerShell or Command Prompt
```powershell
# Navigate to the project directory
cd "C:\Users\JO\Projects\render_tailscaled_kapa-main"
```

### 2. Get Your Tailscale Auth Key
1. Visit [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
2. Click "Generate auth key"
3. Select "Reusable" and appropriate expiration
4. Copy the key (starts with `tskey-auth-`)

### 3. Set Environment Variable
```powershell
# Set the auth key (replace with your actual key)
$env:TAILSCALE_AUTHKEY = "tskey-auth-your-key-here"

# Optional: Set hostname
$env:HOSTNAME = "my-exit-node"
```

### 4. Deploy Using Docker Compose
```powershell
# Build and start the container
docker-compose -f docker-compose.prod.yml up -d --build
```

### 5. Verify Deployment
```powershell
# Check container status
docker-compose -f docker-compose.prod.yml ps

# Check health
curl http://localhost/health

# View logs
docker-compose -f docker-compose.prod.yml logs -f
```

## Alternative: Using WSL2 with Bash Scripts

If you prefer using the bash deployment script:

### 1. Open WSL2 Terminal
```bash
# Navigate to the project (adjust path as needed)
cd /mnt/c/Users/JO/Projects/render_tailscaled_kapa-main
```

### 2. Make Scripts Executable
```bash
chmod +x *.sh
```

### 3. Run Validation
```bash
./validate-setup.sh
```

### 4. Deploy
```bash
# Set environment variables
export TAILSCALE_AUTHKEY="tskey-auth-your-key-here"
export HOSTNAME="my-exit-node"

# Deploy
./deploy.sh
```

## Windows-Specific Commands

### PowerShell Commands
```powershell
# View container logs
docker-compose -f docker-compose.prod.yml logs tailscale-exit-node-prod

# Stop the service
docker-compose -f docker-compose.prod.yml down

# Restart the service
docker-compose -f docker-compose.prod.yml restart

# Clean up everything
docker-compose -f docker-compose.prod.yml down -v --remove-orphans
```

### Check Service Status
```powershell
# Test HTTP health check
Invoke-WebRequest -Uri "http://localhost/health"

# Test HTTPS status (with self-signed cert)
Invoke-WebRequest -Uri "https://localhost/status" -SkipCertificateCheck
```

## Troubleshooting

### Common Issues

1. **Docker not running**
   ```powershell
   # Check Docker status
   docker --version
   docker info
   ```

2. **Port conflicts**
   ```powershell
   # Check what's using port 80/443
   netstat -ano | findstr ":80"
   netstat -ano | findstr ":443"
   ```

3. **Container fails to start**
   ```powershell
   # Check detailed logs
   docker-compose -f docker-compose.prod.yml logs --tail=50 tailscale-exit-node-prod
   ```

4. **Tailscale auth issues**
   - Verify auth key format: must start with `tskey-auth-`
   - Check key hasn't expired
   - Ensure key has correct permissions

### File Permissions (WSL2 only)
```bash
# Fix script permissions
chmod +x deploy.sh security-scan.sh docker-entrypoint.prod.sh

# Fix directory permissions
chmod 755 ssl/ logs/ data/
```

## Monitoring

### View Real-time Logs
```powershell
# All services
docker-compose -f docker-compose.prod.yml logs -f

# Specific service
docker-compose -f docker-compose.prod.yml logs -f tailscale-exit-node-prod
```

### Access Log Files
```powershell
# Navigate to logs directory
cd logs

# View nginx access logs
Get-Content -Path "nginx\access.log" -Tail 20 -Wait

# View tailscale logs
Get-Content -Path "tailscale\tailscaled.out.log" -Tail 20 -Wait
```

### Health Monitoring
```powershell
# Create a simple monitoring script
@"
while (`$true) {
    try {
        `$response = Invoke-WebRequest -Uri "http://localhost/health" -TimeoutSec 5
        Write-Host "Health check OK: `$(`$response.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "Health check FAILED: `$_" -ForegroundColor Red
    }
    Start-Sleep 30
}
"@ | Out-File -FilePath monitor.ps1

# Run the monitor
powershell -ExecutionPolicy Bypass -File monitor.ps1
```

## Production Deployment on claw.cloud

1. **Upload files** to your claw.cloud instance
2. **Set environment variables** in claw.cloud dashboard
3. **Deploy using Docker Compose** or container orchestration
4. **Configure DNS** to point to your instance
5. **Replace SSL certificates** with valid ones
6. **Set up monitoring** and alerting

## Backup and Recovery

### Backup Tailscale State
```powershell
# Create backup
Compress-Archive -Path "data\tailscale" -DestinationPath "backup-$(Get-Date -Format 'yyyyMMdd-HHmm').zip"
```

### Restore from Backup
```powershell
# Stop service
docker-compose -f docker-compose.prod.yml down

# Restore data
Expand-Archive -Path "backup-*.zip" -DestinationPath "data\" -Force

# Start service
docker-compose -f docker-compose.prod.yml up -d
```

## Security Considerations for Windows

1. **Windows Defender**: Add Docker directories to exclusions for better performance
2. **Firewall**: Ensure ports 80, 443, and 41641 are open
3. **Updates**: Keep Docker Desktop updated
4. **Host Security**: Regular Windows updates and antivirus scans

## Support

If you encounter issues:

1. **Check logs** first: `docker-compose -f docker-compose.prod.yml logs`
2. **Run validation**: `./validate-setup.sh` (in WSL2)
3. **Check documentation** in README.md
4. **Review troubleshooting** section in main README

For Windows-specific issues, ensure:
- Docker Desktop is running and healthy
- WSL2 integration is enabled (if using WSL2)
- File paths use forward slashes in Docker commands
- Environment variables are properly set
