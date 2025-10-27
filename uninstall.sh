#!/bin/bash
# uninstall.sh - Remove old failover-manager installation
set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${BLUE}=== Uninstalling Old failover-manager ===${NC}\n"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}" >&2
    echo "Please run: sudo $0" >&2
    exit 1
fi

# Stop and disable service
echo -e "${BLUE}Stopping and disabling service...${NC}"
if systemctl is-active --quiet failover-manager.service 2>/dev/null; then
    systemctl stop failover-manager.service
    echo -e "${GREEN}✓ Service stopped${NC}"
else
    echo -e "${YELLOW}⚠ Service not running${NC}"
fi

if systemctl is-enabled --quiet failover-manager.service 2>/dev/null; then
    systemctl disable failover-manager.service
    echo -e "${GREEN}✓ Service disabled${NC}"
else
    echo -e "${YELLOW}⚠ Service not enabled${NC}"
fi

# Remove systemd service file
if [[ -f /etc/systemd/system/failover-manager.service ]]; then
    rm -f /etc/systemd/system/failover-manager.service
    systemctl daemon-reload
    echo -e "${GREEN}✓ Systemd service file removed${NC}"
else
    echo -e "${YELLOW}⚠ Systemd service file not found${NC}"
fi

# Remove CLI symlink
if [[ -L /usr/local/bin/failover-ctl ]]; then
    rm -f /usr/local/bin/failover-ctl
    echo -e "${GREEN}✓ CLI symlink removed${NC}"
elif [[ -f /usr/local/bin/failover-ctl ]]; then
    rm -f /usr/local/bin/failover-ctl
    echo -e "${GREEN}✓ CLI binary removed${NC}"
else
    echo -e "${YELLOW}⚠ CLI not found${NC}"
fi

# Remove installation directory
if [[ -d /opt/failover-manager ]]; then
    rm -rf /opt/failover-manager
    echo -e "${GREEN}✓ Installation directory removed${NC}"
else
    echo -e "${YELLOW}⚠ Installation directory not found${NC}"
fi

# Backup and remove config directory
if [[ -d /etc/failover-manager ]]; then
    # Create backup
    backup_dir="/tmp/failover-manager-config-backup-$(date +%s)"
    cp -r /etc/failover-manager "$backup_dir"
    echo -e "${GREEN}✓ Config backed up to: $backup_dir${NC}"

    # Remove config directory
    rm -rf /etc/failover-manager
    echo -e "${GREEN}✓ Config directory removed${NC}"
    echo -e "${YELLOW}⚠ You can restore config from: $backup_dir${NC}"
else
    echo -e "${YELLOW}⚠ Config directory not found${NC}"
fi

echo -e "\n${BOLD}${GREEN}=== Uninstallation Complete! ===${NC}\n"
echo -e "${YELLOW}Note: Failover containers created by the old installation are still running.${NC}"
echo -e "${YELLOW}You may want to remove them manually if needed.${NC}\n"
echo -e "${BLUE}To list failover containers: ${BOLD}docker ps | grep failover-${NC}"
echo -e "${BLUE}To remove a failover container: ${BOLD}docker rm -f <container-name>${NC}\n"
