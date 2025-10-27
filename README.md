```
   ____            _  _  __
  / ___|___   ___ | |(_)/ _|_   _
 | |   / _ \ / _ \| || | |_| | | |
 | |__| (_) | (_) | || |  _| |_| |
  \____\___/ \___/|_||_|_|  \__, |
                            |___/
 ███████╗███████╗██████╗  ██████╗
 ╚══███╔╝██╔════╝██╔══██╗██╔═══██╗
   ███╔╝ █████╗  ██████╔╝██║   ██║
  ███╔╝  ██╔══╝  ██╔══██╗██║   ██║
 ███████╗███████╗██║  ██║╚██████╔╝
 ╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝
```

**Zero-downtime deployment manager for Coolify**

Docker-native • Traefik integration • systemd service • Zero config

## What It Does

Eliminates deployment downtime by maintaining hot standby containers that automatically sync after successful deployments.

**Without Coolify Zero:**
- Coolify stops old container before starting new one
- 1-2 minutes of downtime per deployment
- Users see errors, API clients timeout

**With Coolify Zero:**
- Hot standby container always ready
- Traefik routes to failover during deployment
- Primary comes back up → traffic returns → failover syncs
- Zero downtime, zero configuration

## Features

### Automatic Sync
Manager runs as systemd service, maintains hot standby containers, and syncs after successful deployments.

### CLI Management
```bash
# Enable failover for a service
failover-ctl enable translation-api --primary-pattern='api-main'

# Check status
failover-ctl status

# View logs
failover-ctl logs translation-api -f
```

### Traefik Integration
```yaml
# Weighted load balancing with health checks creates true failover behavior
services:
  api-service:
    loadBalancer:
      servers:
        - url: 'http://api-primary:3000'
          weight: 101  # Primary preferred
        - url: 'http://failover-api:3000'
          weight: 1    # Standby
      healthCheck:
        path: /health
        interval: 10s
```

## Installation

```bash
# Quick install (recommended)
curl -fsSL https://raw.githubusercontent.com/light-merlin-dark/coolify-zero/main/install.sh | sudo bash
```

### Verified Install

For those who prefer to verify before running:

```bash
# Download and verify
VERSION=1.0.0
curl -LO https://github.com/light-merlin-dark/coolify-zero/releases/download/v${VERSION}/coolify-zero-${VERSION}.tar.gz
curl -LO https://github.com/light-merlin-dark/coolify-zero/releases/download/v${VERSION}/coolify-zero-${VERSION}.tar.gz.sha256
sha256sum -c coolify-zero-${VERSION}.tar.gz.sha256

# Extract and install
tar -xzf coolify-zero-${VERSION}.tar.gz
cd coolify-zero-${VERSION}
sudo ./install.sh
```

## Quick Start

```bash
# Enable failover for your service
failover-ctl enable my-api \
  --primary-pattern='my-api-prod' \
  --health-endpoint='/health' \
  --health-port=3000

# Check status
failover-ctl status my-api

# Deploy via Coolify -> zero downtime!
```

## How It Works

1. **Manager runs as systemd service**, monitors enabled services every 60s
2. **When primary is healthy**, checks version against failover
3. **Version mismatch detected** → recreates failover from primary image
4. **During deployment:**
   - Primary goes unhealthy → Traefik routes to failover
   - New primary comes up → Traefik routes back
   - Manager syncs failover to new version

```
Normal:    User → Traefik → Primary (healthy) + Failover (standby)
Deploy:    User → Traefik → Primary (down) → Failover (serving)
After:     User → Traefik → Primary (new version) + Failover (syncing)
```

## Requirements

**System:**
- Linux with systemd
- Docker daemon
- Coolify installation
- Traefik reverse proxy

**Dependencies:**
- bash 4.0+
- jq
- curl

**Services must have:**
- Health check endpoint (e.g., `/health`)
- Version identifier in health response

**Volume Mounting:**
- Failover containers automatically inherit the same volume mounts as primary
- Works with stateful services (SQLite, file uploads, sessions)
- Data written during failover is preserved when primary recovers

## CLI Commands

```bash
# Enable failover for a service
failover-ctl enable <service> [options]

# Disable and cleanup failover
failover-ctl disable <service>

# Show service status
failover-ctl status [service]

# List all managed services
failover-ctl list

# View logs
failover-ctl logs <service> [-f]

# Show Traefik config instructions
failover-ctl traefik <service>

# Force immediate sync
failover-ctl sync <service>

# Validate configuration
failover-ctl validate
```

## Uninstall

```bash
# Disable all services first
failover-ctl list | xargs -I {} failover-ctl disable {}

# Stop and disable service
sudo systemctl stop failover-manager
sudo systemctl disable failover-manager

# Remove files
sudo rm -rf /opt/failover-manager
sudo rm /usr/local/bin/failover-ctl
sudo rm /etc/systemd/system/failover-manager.service
sudo rm -rf /etc/failover-manager
```

## Configuration

Configuration stored in `/etc/failover-manager/config.yaml`:

```yaml
manager:
  check_interval: 60  # seconds between sync checks
  log_level: info
  docker_network: coolify

services:
  my-api:
    enabled: true
    primary_pattern: "my-api-prod"
    health_endpoint: "/health"
    health_port: 3000
    version_jq_path: ".version"
```

## Troubleshooting

### Manager not syncing
```bash
# Check manager logs
journalctl -u failover-manager -f

# Check service status
failover-ctl status my-api

# Manually trigger sync
failover-ctl sync my-api
```

### Failover not receiving traffic
```bash
# Verify Traefik config includes failover URL
cat /data/coolify/proxy/dynamic/my-service.yaml

# Check failover health
docker logs failover-my-api
```

### Primary not found
```bash
# List containers matching pattern
docker ps --filter name=my-pattern

# Update pattern if needed
failover-ctl disable my-api
failover-ctl enable my-api --primary-pattern='new-pattern' ...
```

## License

MIT License - see [LICENSE](LICENSE) file for details.

---

Built by [@EnchantedRobot](https://x.com/EnchantedRobot)
