#!/bin/bash
# coolify-zero-ctl.sh - CLI tool for managing failover containers
set -euo pipefail

# Get actual script directory (resolve symlinks)
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Source library functions
# shellcheck source=../lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=../lib/docker.sh
source "$LIB_DIR/docker.sh"
# shellcheck source=../lib/health.sh
source "$LIB_DIR/health.sh"
# shellcheck source=../lib/traefik.sh
source "$LIB_DIR/traefik.sh"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Version
VERSION="1.0.0"

# Show usage
usage() {
    cat <<EOF
${BOLD}Coolify Zero${NC} - CLI Tool v$VERSION

${BOLD}USAGE:${NC}
  coolify-zero <command> [options]

${BOLD}COMMANDS:${NC}
  ${GREEN}enable${NC} <service>              Enable failover for a service
    --primary-pattern <pattern>   Pattern to find primary container
    --health-endpoint <path>      Health check endpoint (default: /health)
    --health-port <port>          Health check port (default: 3000)
    --version-path <jq-path>      JQ path to version (default: .version)

  ${GREEN}disable${NC} <service>             Disable and cleanup failover

  ${GREEN}status${NC} [service]              Show service status (or all if no service)

  ${GREEN}list${NC}                          List all managed services

  ${GREEN}logs${NC} <service> [-f]           View service logs (-f to follow)

  ${GREEN}traefik${NC} <service>             Show Traefik config instructions

  ${GREEN}sync${NC} <service>                Force immediate failover sync

  ${GREEN}validate${NC}                      Validate configuration file

  ${GREEN}version${NC}                       Show version information

  ${GREEN}help${NC}                          Show this help message

${BOLD}EXAMPLES:${NC}
  # Enable failover for translation-api
  coolify-zero enable translation-api \\
    --primary-pattern='translation-api-eo' \\
    --health-endpoint='/health' \\
    --health-port=3000 \\
    --version-path='.engineVersion'

  # Check status
  coolify-zero status translation-api

  # View logs
  coolify-zero logs translation-api -f

  # Disable failover
  coolify-zero disable translation-api

EOF
}

# Enable command
cmd_enable() {
    local service=""
    local primary_pattern=""
    local health_endpoint="/health"
    local health_port="3000"
    local version_path=".version"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --primary-pattern=*)
                primary_pattern="${1#*=}"
                shift
                ;;
            --health-endpoint=*)
                health_endpoint="${1#*=}"
                shift
                ;;
            --health-port=*)
                health_port="${1#*=}"
                shift
                ;;
            --version-path=*)
                version_path="${1#*=}"
                shift
                ;;
            *)
                if [[ -z "$service" ]]; then
                    service="$1"
                else
                    echo -e "${RED}ERROR: Unknown option: $1${NC}" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$service" ]]; then
        echo -e "${RED}ERROR: Service name required${NC}" >&2
        echo "Usage: coolify-zero enable <service> --primary-pattern=<pattern>" >&2
        exit 1
    fi

    if [[ -z "$primary_pattern" ]]; then
        echo -e "${RED}ERROR: --primary-pattern required${NC}" >&2
        exit 1
    fi

    echo -e "${BLUE}Enabling failover for service: $service${NC}"

    # Add service to config
    if add_service "$service" "$primary_pattern" "$health_endpoint" "$health_port" "$version_path"; then
        echo -e "${GREEN}✓ Service added to configuration${NC}"
    else
        echo -e "${RED}✗ Failed to add service to configuration${NC}" >&2
        exit 1
    fi

    # Find primary container
    echo -e "\n${BLUE}Looking for primary container (pattern: $primary_pattern)...${NC}"
    local primary_id
    primary_id=$(find_container "$primary_pattern")

    if [[ -z "$primary_id" ]]; then
        echo -e "${YELLOW}⚠ Primary container not found${NC}" >&2
        echo -e "The service has been added to config, but failover won't be created until primary is running." >&2
        exit 0
    fi

    local primary_name
    primary_name=$(get_container_name "$primary_id")
    echo -e "${GREEN}✓ Found primary: $primary_name${NC}"

    # Create failover container
    echo -e "\n${BLUE}Creating failover container...${NC}"
    local failover_name="failover-${service}"
    local docker_network
    docker_network=$(get_manager_setting "docker_network")
    docker_network=${docker_network:-coolify}

    if create_failover_container "$primary_id" "$failover_name" "$docker_network"; then
        echo -e "${GREEN}✓ Failover container created${NC}"
    else
        echo -e "${RED}✗ Failed to create failover container${NC}" >&2
        exit 1
    fi

    # Wait for failover to become healthy
    echo -e "\n${BLUE}Checking failover health...${NC}"
    sleep 2  # Give it a moment to start

    if http_health_check "$failover_name" "$health_endpoint" "$health_port"; then
        local version
        version=$(get_version "$failover_name" "$health_endpoint" "$health_port" "$version_path" 2>/dev/null || echo "unknown")
        echo -e "${GREEN}✓ Failover is healthy (version: $version)${NC}"
    else
        echo -e "${YELLOW}⚠ Failover created but not healthy yet (may need more time)${NC}" >&2
    fi

    # Auto-configure Traefik
    if auto_configure_traefik "$service" "$primary_id" "$failover_name" "$health_endpoint" "$health_port"; then
        echo -e "${GREEN}✓ Traefik configuration updated${NC}"
        traefik_configured=true
    else
        echo -e "${YELLOW}⚠ Traefik auto-configuration failed or skipped${NC}"
        traefik_configured=false
    fi

    # Show next steps
    echo -e "\n${BOLD}${GREEN}✓ Failover enabled successfully!${NC}"

    if [[ "$traefik_configured" == "false" ]]; then
        echo -e "\n${BOLD}NEXT STEPS:${NC}"
        echo -e "1. Update Traefik configuration manually:"
        echo -e "   ${CYAN}coolify-zero traefik $service${NC}"
        echo -e "\n2. Check status:"
        echo -e "   ${CYAN}coolify-zero status $service${NC}"
        echo -e "\n3. Monitor manager logs:"
        echo -e "   ${CYAN}journalctl -u coolify-zero -f${NC}"
    else
        echo -e "\n${BOLD}NEXT STEPS:${NC}"
        echo -e "1. Check status:"
        echo -e "   ${CYAN}coolify-zero status $service${NC}"
        echo -e "\n2. Monitor manager logs:"
        echo -e "   ${CYAN}journalctl -u coolify-zero -f${NC}"
        echo -e "\n3. Test deployment:"
        echo -e "   Deploy via Coolify and verify zero downtime"
    fi
}

# Disable command
cmd_disable() {
    local service="$1"

    if [[ -z "$service" ]]; then
        echo -e "${RED}ERROR: Service name required${NC}" >&2
        echo "Usage: coolify-zero disable <service>" >&2
        exit 1
    fi

    echo -e "${BLUE}Disabling failover for service: $service${NC}"

    # Check if service exists
    if ! list_services | grep -q "^$service$"; then
        echo -e "${RED}ERROR: Service '$service' not found in configuration${NC}" >&2
        exit 1
    fi

    # Stop and remove failover container
    local failover_name="failover-${service}"
    if container_exists "$failover_name"; then
        echo -e "${BLUE}Removing failover container: $failover_name${NC}"
        stop_container "$failover_name"
        remove_container "$failover_name"
        echo -e "${GREEN}✓ Failover container removed${NC}"
    else
        echo -e "${YELLOW}Failover container not found (already removed?)${NC}"
    fi

    # Remove from config
    if remove_service "$service"; then
        echo -e "${GREEN}✓ Service removed from configuration${NC}"
    else
        echo -e "${RED}✗ Failed to remove service from configuration${NC}" >&2
        exit 1
    fi

    echo -e "\n${BOLD}${GREEN}✓ Failover disabled successfully!${NC}"
    echo -e "\n${BOLD}NOTE:${NC} Don't forget to remove the failover URL from Traefik configuration"
}

# Status command
cmd_status() {
    local service="${1:-}"

    if [[ -n "$service" ]]; then
        # Show status for specific service
        show_service_status "$service"
    else
        # Show status for all services
        local services
        services=$(list_services)

        if [[ -z "$services" ]]; then
            echo -e "${YELLOW}No services configured${NC}"
            exit 0
        fi

        echo -e "${BOLD}=== Failover Manager Status ===${NC}\n"

        for svc in $services; do
            show_service_status "$svc"
            echo ""
        done
    fi
}

# Show status for a single service
show_service_status() {
    local service="$1"

    # Check if service exists
    if ! list_services | grep -q "^$service$"; then
        echo -e "${RED}ERROR: Service '$service' not found in configuration${NC}" >&2
        exit 1
    fi

    # Get service config
    local enabled
    local primary_pattern
    local health_endpoint
    local health_port
    local version_path

    enabled=$(get_service_setting "$service" "enabled")
    primary_pattern=$(get_service_setting "$service" "primary_pattern")
    health_endpoint=$(get_service_setting "$service" "health_endpoint")
    health_port=$(get_service_setting "$service" "health_port")
    version_path=$(get_service_setting "$service" "version_jq_path")

    echo -e "${BOLD}Service: $service${NC}"
    echo -e "  Enabled: $([ "$enabled" == "true" ] && echo -e "${GREEN}yes${NC}" || echo -e "${RED}no${NC}")"
    echo -e "  Primary pattern: $primary_pattern"

    # Find primary
    local primary_id
    primary_id=$(find_container "$primary_pattern")

    if [[ -n "$primary_id" ]]; then
        local primary_name
        primary_name=$(get_container_name "$primary_id")

        echo -e "  Primary: ${GREEN}$primary_name${NC}"

        # Check primary health
        if http_health_check "$primary_name" "$health_endpoint" "$health_port"; then
            local primary_version
            primary_version=$(get_version "$primary_name" "$health_endpoint" "$health_port" "$version_path" 2>/dev/null || echo "unknown")
            echo -e "    Status: ${GREEN}✓ Healthy${NC}"
            echo -e "    Version: $primary_version"
        else
            echo -e "    Status: ${RED}✗ Unhealthy${NC}"
        fi
    else
        echo -e "  Primary: ${RED}Not found${NC}"
    fi

    # Check failover
    local failover_name="failover-${service}"
    if container_exists "$failover_name"; then
        echo -e "  Failover: ${GREEN}$failover_name${NC}"

        # Check failover health
        if http_health_check "$failover_name" "$health_endpoint" "$health_port"; then
            local failover_version
            failover_version=$(get_version "$failover_name" "$health_endpoint" "$health_port" "$version_path" 2>/dev/null || echo "unknown")
            echo -e "    Status: ${GREEN}✓ Healthy${NC}"
            echo -e "    Version: $failover_version"

            # Check version sync
            if [[ -n "$primary_id" ]]; then
                local primary_version
                primary_version=$(get_version "$primary_name" "$health_endpoint" "$health_port" "$version_path" 2>/dev/null || echo "")

                if [[ -n "$primary_version" ]] && versions_match "$primary_version" "$failover_version"; then
                    echo -e "    Sync: ${GREEN}✓ In sync${NC}"
                else
                    echo -e "    Sync: ${YELLOW}⚠ Out of sync${NC} (manager will sync soon)"
                fi
            fi
        else
            echo -e "    Status: ${RED}✗ Unhealthy${NC}"
        fi
    else
        echo -e "  Failover: ${YELLOW}Not found${NC}"
    fi
}

# List command
cmd_list() {
    local services
    services=$(list_services)

    if [[ -z "$services" ]]; then
        echo -e "${YELLOW}No services configured${NC}"
        exit 0
    fi

    echo -e "${BOLD}=== Managed Services ===${NC}\n"

    printf "%-20s %-10s %-15s %-15s\n" "SERVICE" "ENABLED" "PRIMARY" "FAILOVER"
    printf "%-20s %-10s %-15s %-15s\n" "-------" "-------" "-------" "--------"

    for service in $services; do
        local enabled
        local primary_pattern
        local health_endpoint
        local health_port

        enabled=$(get_service_setting "$service" "enabled")
        primary_pattern=$(get_service_setting "$service" "primary_pattern")
        health_endpoint=$(get_service_setting "$service" "health_endpoint")
        health_port=$(get_service_setting "$service" "health_port")

        local enabled_str="no"
        [[ "$enabled" == "true" ]] && enabled_str="yes"

        # Check primary
        local primary_status="not found"
        local primary_id
        primary_id=$(find_container "$primary_pattern")
        if [[ -n "$primary_id" ]]; then
            local primary_name
            primary_name=$(get_container_name "$primary_id")
            if http_health_check "$primary_name" "$health_endpoint" "$health_port" 2>/dev/null; then
                primary_status="healthy"
            else
                primary_status="unhealthy"
            fi
        fi

        # Check failover
        local failover_status="not found"
        local failover_name="failover-${service}"
        if container_exists "$failover_name"; then
            if http_health_check "$failover_name" "$health_endpoint" "$health_port" 2>/dev/null; then
                failover_status="healthy"
            else
                failover_status="unhealthy"
            fi
        fi

        printf "%-20s %-10s %-15s %-15s\n" "$service" "$enabled_str" "$primary_status" "$failover_status"
    done
}

# Logs command
cmd_logs() {
    local service="$1"
    local follow="${2:-}"

    if [[ -z "$service" ]]; then
        echo -e "${RED}ERROR: Service name required${NC}" >&2
        echo "Usage: coolify-zero logs <service> [-f]" >&2
        exit 1
    fi

    local failover_name="failover-${service}"

    if ! container_exists "$failover_name"; then
        echo -e "${RED}ERROR: Failover container not found: $failover_name${NC}" >&2
        exit 1
    fi

    echo -e "${BLUE}=== Logs for $failover_name ===${NC}\n"

    if [[ "$follow" == "-f" ]]; then
        follow_container_logs "$failover_name"
    else
        get_container_logs "$failover_name" 100
    fi
}

# Traefik command
cmd_traefik() {
    local service="$1"

    if [[ -z "$service" ]]; then
        echo -e "${RED}ERROR: Service name required${NC}" >&2
        echo "Usage: coolify-zero traefik <service>" >&2
        exit 1
    fi

    local failover_name="failover-${service}"
    local health_endpoint
    local health_port

    health_endpoint=$(get_service_setting "$service" "health_endpoint")
    health_port=$(get_service_setting "$service" "health_port")

    cat <<EOF
${BOLD}=== Traefik Configuration for $service ===${NC}

${GREEN}NOTE: Traefik configuration is automatically created during 'coolify-zero enable'${NC}
${GREEN}These manual instructions are provided for reference or troubleshooting.${NC}

To enable zero-downtime deployments, add the failover container to your
Traefik load balancer configuration.

${BOLD}1. Find your Traefik config file:${NC}
   Typically: ${CYAN}/data/coolify/proxy/dynamic/${service}.yaml${NC}

${BOLD}2. Edit the loadBalancer section:${NC}

   ${GREEN}Before:${NC}
   services:
     ${service}-service:
       loadBalancer:
         servers:
           - url: 'http://${service}:${health_port}'
         healthCheck:
           path: ${health_endpoint}
           interval: 30s
           timeout: 3s

   ${GREEN}After (ADD the failover URL and reduce interval):${NC}
   services:
     ${service}-service:
       loadBalancer:
         servers:
           - url: 'http://${service}:${health_port}'
           - url: 'http://${failover_name}:${health_port}'  ${YELLOW}# ADD THIS${NC}
         healthCheck:
           path: ${health_endpoint}
           interval: 10s  ${YELLOW}# CHANGE from 30s to 10s${NC}
           timeout: 3s

${BOLD}3. Reload Traefik:${NC}
   Traefik watches this directory and will reload automatically.
   You can verify with: ${CYAN}docker logs coolify-proxy${NC}

${BOLD}4. Test:${NC}
   ${CYAN}curl -I https://your-service-domain.com${health_endpoint}${NC}

${BOLD}Why 10s interval?${NC}
   - Faster failover detection during deployments
   - 30s would mean 30s downtime before switching to failover
   - 10s is a good balance (quick enough, not too aggressive)

EOF
}

# Sync command - force immediate failover recreation
cmd_sync() {
    local service="$1"

    if [[ -z "$service" ]]; then
        echo -e "${RED}ERROR: Service name required${NC}" >&2
        echo "Usage: coolify-zero sync <service>"
        exit 1
    fi

    # Verify service is enabled
    if ! get_config "services.${service}.enabled" | grep -q "true"; then
        echo -e "${RED}ERROR: Service '$service' is not enabled${NC}" >&2
        echo "Run 'coolify-zero enable $service' first"
        exit 1
    fi

    local failover_name="failover-${service}"

    echo -e "${BLUE}Force syncing failover for: ${BOLD}$service${NC}"
    echo ""

    # Check if failover exists
    if ! container_exists "$failover_name"; then
        echo -e "${YELLOW}⚠ Failover container does not exist yet${NC}"
        echo -e "${BLUE}Manager will create it on next check cycle (within 60s)${NC}"
        exit 0
    fi

    # Remove the failover container
    echo -e "${BLUE}Removing failover container: $failover_name${NC}"

    if remove_container "$failover_name"; then
        echo -e "${GREEN}✓ Failover container removed${NC}"
        echo ""
        echo -e "${BLUE}The manager will recreate it on the next check cycle.${NC}"
        echo -e "${BLUE}Check interval: $(get_config 'manager.check_interval' || echo '60')s${NC}"
        echo ""
        echo -e "Monitor with: ${CYAN}coolify-zero status $service${NC}"
        exit 0
    else
        echo -e "${RED}✗ Failed to remove failover container${NC}" >&2
        exit 1
    fi
}

# Validate command
cmd_validate() {
    echo -e "${BLUE}Validating configuration...${NC}\n"

    if validate_config; then
        echo -e "\n${GREEN}✓ Configuration is valid${NC}"
        exit 0
    else
        echo -e "\n${RED}✗ Configuration has errors${NC}" >&2
        exit 1
    fi
}

# Version command
cmd_version() {
    echo "Coolify Zero v$VERSION"
}

# Main command dispatcher
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        enable)
            cmd_enable "$@"
            ;;
        disable)
            cmd_disable "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        logs)
            cmd_logs "$@"
            ;;
        traefik)
            cmd_traefik "$@"
            ;;
        sync)
            cmd_sync "$@"
            ;;
        validate)
            cmd_validate "$@"
            ;;
        version)
            cmd_version "$@"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            echo -e "${RED}ERROR: Unknown command: $command${NC}" >&2
            echo ""
            usage
            exit 1
            ;;
    esac
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
