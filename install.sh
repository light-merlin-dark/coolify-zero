#!/bin/bash
# install.sh - One-command installation script for Coolify Zero
set -eo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Installation paths
INSTALL_DIR="/opt/coolify-zero"
CONFIG_DIR="/etc/coolify-zero"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
GITHUB_REPO="light-merlin-dark/coolify-zero"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main"

# Get script directory (where this install.sh is located)
# If piped from curl, BASH_SOURCE will be empty, so download files from GitHub
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "bash" ]]; then
    # Running from curl pipe - download to temp directory
    SCRIPT_DIR=$(mktemp -d)
    echo -e "${BLUE}Downloading files from GitHub...${NC}"

    # Download all necessary files
    mkdir -p "$SCRIPT_DIR/bin" "$SCRIPT_DIR/lib" "$SCRIPT_DIR/systemd"
    curl -fsSL "${GITHUB_RAW}/bin/coolify-zero.sh" -o "$SCRIPT_DIR/bin/coolify-zero.sh"
    curl -fsSL "${GITHUB_RAW}/bin/coolify-zero-ctl.sh" -o "$SCRIPT_DIR/bin/coolify-zero-ctl.sh"
    curl -fsSL "${GITHUB_RAW}/lib/config.sh" -o "$SCRIPT_DIR/lib/config.sh"
    curl -fsSL "${GITHUB_RAW}/lib/docker.sh" -o "$SCRIPT_DIR/lib/docker.sh"
    curl -fsSL "${GITHUB_RAW}/lib/health.sh" -o "$SCRIPT_DIR/lib/health.sh"
    curl -fsSL "${GITHUB_RAW}/lib/traefik.sh" -o "$SCRIPT_DIR/lib/traefik.sh"
    curl -fsSL "${GITHUB_RAW}/systemd/coolify-zero.service" -o "$SCRIPT_DIR/systemd/coolify-zero.service"

    echo -e "${GREEN}✓ Files downloaded${NC}\n"
else
    # Running from local file
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

echo -e "${BOLD}${BLUE}=== Coolify Zero Installation ===${NC}\n"

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}ERROR: This script must be run as root${NC}" >&2
        echo "Please run: sudo $0" >&2
        exit 1
    fi
}

# Check prerequisites
check_prerequisites() {
    echo -e "${BLUE}Checking prerequisites...${NC}"

    local missing=0

    # Check bash version
    if [[ -z "${BASH_VERSION:-}" ]]; then
        echo -e "${RED}✗ bash not found${NC}"
        missing=1
    else
        local bash_major="${BASH_VERSION%%.*}"
        if [[ $bash_major -lt 4 ]]; then
            echo -e "${RED}✗ bash 4.0+ required (found $BASH_VERSION)${NC}"
            missing=1
        else
            echo -e "${GREEN}✓ bash $BASH_VERSION${NC}"
        fi
    fi

    # Check docker
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}✗ docker not found${NC}"
        missing=1
    else
        if docker info >/dev/null 2>&1; then
            local docker_version
            docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
            echo -e "${GREEN}✓ docker $docker_version${NC}"
        else
            echo -e "${RED}✗ docker daemon not accessible${NC}"
            echo "  Make sure Docker is running and you have permissions" >&2
            missing=1
        fi
    fi

    # Check jq
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}✗ jq not found${NC}"
        echo "  Install with: apt-get install jq  or  yum install jq" >&2
        missing=1
    else
        local jq_version
        jq_version=$(jq --version 2>&1 | cut -d'-' -f2)
        echo -e "${GREEN}✓ jq $jq_version${NC}"
    fi

    # Check curl
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}✗ curl not found${NC}"
        echo "  Install with: apt-get install curl  or  yum install curl" >&2
        missing=1
    else
        local curl_version
        curl_version=$(curl --version | head -n1 | cut -d' ' -f2)
        echo -e "${GREEN}✓ curl $curl_version${NC}"
    fi

    # Check systemd
    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}✗ systemd not found${NC}"
        echo "  This tool requires systemd for service management" >&2
        missing=1
    else
        echo -e "${GREEN}✓ systemd${NC}"
    fi

    # Check yq (optional)
    if command -v yq >/dev/null 2>&1; then
        local yq_version
        yq_version=$(yq --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -n1 || echo "unknown")
        echo -e "${GREEN}✓ yq $yq_version (optional, recommended)${NC}"
    else
        echo -e "${YELLOW}⚠ yq not found (optional, but recommended)${NC}"
        echo "  Install with: wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && chmod +x /usr/local/bin/yq"
    fi

    if [[ $missing -gt 0 ]]; then
        echo -e "\n${RED}✗ Prerequisites check failed${NC}" >&2
        echo "Please install missing dependencies and try again." >&2
        exit 1
    fi

    echo -e "${GREEN}✓ All prerequisites met${NC}\n"
}

# Create directories
create_directories() {
    echo -e "${BLUE}Creating directories...${NC}"

    mkdir -p "$INSTALL_DIR/bin"
    mkdir -p "$INSTALL_DIR/lib"
    mkdir -p "$CONFIG_DIR"

    echo -e "${GREEN}✓ Directories created${NC}\n"
}

# Install scripts
install_scripts() {
    echo -e "${BLUE}Installing scripts...${NC}"

    # Copy library files
    cp "$SCRIPT_DIR/lib/config.sh" "$INSTALL_DIR/lib/"
    cp "$SCRIPT_DIR/lib/docker.sh" "$INSTALL_DIR/lib/"
    cp "$SCRIPT_DIR/lib/health.sh" "$INSTALL_DIR/lib/"
    cp "$SCRIPT_DIR/lib/traefik.sh" "$INSTALL_DIR/lib/"
    echo -e "${GREEN}✓ Library files installed${NC}"

    # Copy binaries
    cp "$SCRIPT_DIR/bin/coolify-zero.sh" "$INSTALL_DIR/bin/"
    cp "$SCRIPT_DIR/bin/coolify-zero-ctl.sh" "$INSTALL_DIR/bin/"
    echo -e "${GREEN}✓ Binary files installed${NC}"

    # Make scripts executable
    chmod +x "$INSTALL_DIR/bin/coolify-zero.sh"
    chmod +x "$INSTALL_DIR/bin/coolify-zero-ctl.sh"
    chmod +x "$INSTALL_DIR/lib/"*.sh
    echo -e "${GREEN}✓ Scripts made executable${NC}"

    # Create symlink for CLI
    ln -sf "$INSTALL_DIR/bin/coolify-zero-ctl.sh" "$BIN_DIR/coolify-zero"
    echo -e "${GREEN}✓ CLI symlink created: $BIN_DIR/coolify-zero${NC}\n"
}

# Create config file
create_config() {
    echo -e "${BLUE}Creating configuration file...${NC}"

    if [[ -f "$CONFIG_DIR/config.yaml" ]]; then
        echo -e "${YELLOW}⚠ Config file already exists, creating backup${NC}"
        cp "$CONFIG_DIR/config.yaml" "$CONFIG_DIR/config.yaml.backup.$(date +%s)"
    fi

    cat > "$CONFIG_DIR/config.yaml" <<'EOF'
# Coolify Zero Configuration

manager:
  # How often to check and sync failover containers (seconds)
  check_interval: 60

  # Log level: debug, info, warn, error
  log_level: info

  # Docker network where containers run
  docker_network: coolify

# Services to manage
# Add services using: coolify-zero enable <service> [options]
services: {}
EOF

    chmod 600 "$CONFIG_DIR/config.yaml"
    echo -e "${GREEN}✓ Configuration file created: $CONFIG_DIR/config.yaml${NC}\n"
}

# Create systemd service
create_systemd_service() {
    echo -e "${BLUE}Creating systemd service...${NC}"

    cat > "$SYSTEMD_DIR/coolify-zero.service" <<EOF
[Unit]
Description=Coolify Zero - Zero-downtime deployment manager
Documentation=https://github.com/light-merlin-dark/coolify-zero
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=$INSTALL_DIR/bin/coolify-zero.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=coolify-zero

# Security settings
NoNewPrivileges=true
PrivateTmp=true

# Environment
Environment="CONFIG_FILE=$CONFIG_DIR/config.yaml"

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${GREEN}✓ Systemd service created${NC}\n"
}

# Enable and start service
enable_service() {
    echo -e "${BLUE}Enabling and starting service...${NC}"

    # Reload systemd
    systemctl daemon-reload
    echo -e "${GREEN}✓ Systemd reloaded${NC}"

    # Enable service
    systemctl enable coolify-zero.service
    echo -e "${GREEN}✓ Service enabled${NC}"

    # Start service
    systemctl start coolify-zero.service
    echo -e "${GREEN}✓ Service started${NC}\n"

    # Check status
    sleep 2
    if systemctl is-active --quiet coolify-zero.service; then
        echo -e "${GREEN}✓ Service is running${NC}\n"
    else
        echo -e "${RED}✗ Service failed to start${NC}" >&2
        echo "Check logs with: journalctl -u coolify-zero -n 50" >&2
        exit 1
    fi
}

# Show success message
show_success() {
    cat <<EOF
${BOLD}${GREEN}=== Installation Complete! ===${NC}

${BOLD}What's Installed:${NC}
  - Manager daemon: $INSTALL_DIR/bin/coolify-zero.sh
  - CLI tool: $BIN_DIR/coolify-zero
  - Libraries: $INSTALL_DIR/lib/
  - Config: $CONFIG_DIR/config.yaml
  - Service: coolify-zero.service

${BOLD}Next Steps:${NC}

${BOLD}1. Enable failover for a service:${NC}
   ${BLUE}coolify-zero enable <service-name> \\
     --primary-pattern='<pattern-to-find-primary>' \\
     --health-endpoint='/health' \\
     --health-port=3000 \\
     --version-path='.version'${NC}

   ${BOLD}Example for translation-api:${NC}
   ${BLUE}coolify-zero enable translation-api \\
     --primary-pattern='translation-api-eo' \\
     --health-endpoint='/health' \\
     --health-port=3000 \\
     --version-path='.engineVersion'${NC}

${BOLD}2. Update Traefik configuration:${NC}
   ${BLUE}coolify-zero traefik <service-name>${NC}

   Follow the instructions to add failover URL to your Traefik config.

${BOLD}3. Check status:${NC}
   ${BLUE}coolify-zero status${NC}
   ${BLUE}coolify-zero list${NC}

${BOLD}4. Monitor logs:${NC}
   ${BLUE}journalctl -u coolify-zero -f${NC}

${BOLD}Useful Commands:${NC}
  coolify-zero help              - Show help
  coolify-zero list              - List all services
  coolify-zero status [service]  - Show service status
  coolify-zero logs <service>    - View service logs
  coolify-zero disable <service> - Disable failover

${BOLD}Configuration:${NC}
  Edit: $CONFIG_DIR/config.yaml
  Validate: ${BLUE}coolify-zero validate${NC}

${BOLD}Service Management:${NC}
  Status:  ${BLUE}systemctl status coolify-zero${NC}
  Restart: ${BLUE}systemctl restart coolify-zero${NC}
  Logs:    ${BLUE}journalctl -u coolify-zero -f${NC}

${GREEN}Happy deploying with zero downtime! 🚀${NC}

EOF
}

# Main installation
main() {
    check_root
    check_prerequisites
    create_directories
    install_scripts
    create_config
    create_systemd_service
    enable_service
    show_success

    # Cleanup temp directory if we downloaded files
    if [[ "$SCRIPT_DIR" == /tmp/* ]]; then
        rm -rf "$SCRIPT_DIR"
    fi
}

# Run main
main "$@"
