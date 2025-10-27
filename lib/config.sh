#!/bin/bash
# config.sh - Configuration file parsing and management

# Default config file location
CONFIG_FILE="${CONFIG_FILE:-/etc/coolify-zero/config.yaml}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if yq is available
HAS_YQ=false
if command -v yq >/dev/null 2>&1; then
    HAS_YQ=true
fi

# Validate config file exists
validate_config_file() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}ERROR: Config file not found: $CONFIG_FILE${NC}" >&2
        return 1
    fi
    return 0
}

# Get manager setting
# Usage: get_manager_setting "check_interval"
get_manager_setting() {
    local key="$1"
    validate_config_file || return 1

    if [[ "$HAS_YQ" == "true" ]]; then
        yq eval ".manager.$key" "$CONFIG_FILE" 2>/dev/null
    else
        # Fallback: grep/sed parsing
        grep -A 10 "^manager:" "$CONFIG_FILE" | \
            grep "^  $key:" | \
            sed 's/.*: *//' | \
            head -n 1
    fi
}

# Get service setting
# Usage: get_service_setting "translation-api" "primary_pattern"
get_service_setting() {
    local service="$1"
    local key="$2"
    validate_config_file || return 1

    if [[ "$HAS_YQ" == "true" ]]; then
        yq eval ".services.$service.$key" "$CONFIG_FILE" 2>/dev/null
    else
        # Fallback: grep/sed parsing
        # Find the service block, then find the key
        awk "/^  $service:/,/^  [a-zA-Z]/" "$CONFIG_FILE" | \
            grep "^    $key:" | \
            sed 's/.*: *//' | \
            head -n 1
    fi
}

# List all services
# Returns space-separated list of service names
list_services() {
    validate_config_file || return 1

    if [[ "$HAS_YQ" == "true" ]]; then
        yq eval '.services | keys | .[]' "$CONFIG_FILE" 2>/dev/null
    else
        # Fallback: grep/sed parsing
        # Find lines that are 2-space indented under services (service names)
        awk '/^services:/,/^[a-zA-Z]/' "$CONFIG_FILE" | \
            grep "^  [a-zA-Z]" | \
            sed 's/^  //' | \
            sed 's/:.*//'
    fi
}

# Check if service is enabled
# Usage: is_service_enabled "translation-api"
is_service_enabled() {
    local service="$1"
    local enabled
    enabled=$(get_service_setting "$service" "enabled")

    if [[ "$enabled" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Get all enabled services
# Returns space-separated list of enabled service names
get_enabled_services() {
    local services
    services=$(list_services)

    local enabled_services=""
    for service in $services; do
        if is_service_enabled "$service"; then
            enabled_services="$enabled_services $service"
        fi
    done

    echo "$enabled_services" | xargs
}

# Update service setting
# Usage: update_service_setting "translation-api" "enabled" "true"
update_service_setting() {
    local service="$1"
    local key="$2"
    local value="$3"
    validate_config_file || return 1

    if [[ "$HAS_YQ" == "true" ]]; then
        # Use yq to update in-place
        yq eval -i ".services.$service.$key = \"$value\"" "$CONFIG_FILE"
    else
        # Fallback: manual editing is complex, recommend yq installation
        echo -e "${YELLOW}WARNING: yq not found. Manual config editing required.${NC}" >&2
        echo "Please install yq or manually edit: $CONFIG_FILE" >&2
        echo "Set: services.$service.$key = $value" >&2
        return 1
    fi
}

# Add new service to config
# Usage: add_service "service-name" "primary-pattern" "health-endpoint" "health-port" "version-path"
add_service() {
    local service="$1"
    local primary_pattern="$2"
    local health_endpoint="$3"
    local health_port="$4"
    local version_path="$5"

    validate_config_file || return 1

    # Check if service already exists
    if list_services | grep -q "^$service$"; then
        echo -e "${YELLOW}WARNING: Service '$service' already exists in config${NC}" >&2
        return 1
    fi

    if [[ "$HAS_YQ" == "true" ]]; then
        yq eval -i ".services.$service.enabled = true" "$CONFIG_FILE"
        yq eval -i ".services.$service.primary_pattern = \"$primary_pattern\"" "$CONFIG_FILE"
        yq eval -i ".services.$service.health_endpoint = \"$health_endpoint\"" "$CONFIG_FILE"
        yq eval -i ".services.$service.health_port = $health_port" "$CONFIG_FILE"
        yq eval -i ".services.$service.version_jq_path = \"$version_path\"" "$CONFIG_FILE"
        echo -e "${GREEN}✓ Service '$service' added to config${NC}"
    else
        echo -e "${YELLOW}WARNING: yq not found. Cannot add service automatically.${NC}" >&2
        echo "Please install yq or manually add to $CONFIG_FILE:" >&2
        echo "" >&2
        echo "services:" >&2
        echo "  $service:" >&2
        echo "    enabled: true" >&2
        echo "    primary_pattern: \"$primary_pattern\"" >&2
        echo "    health_endpoint: \"$health_endpoint\"" >&2
        echo "    health_port: $health_port" >&2
        echo "    version_jq_path: \"$version_path\"" >&2
        return 1
    fi
}

# Remove service from config
# Usage: remove_service "service-name"
remove_service() {
    local service="$1"
    validate_config_file || return 1

    if [[ "$HAS_YQ" == "true" ]]; then
        yq eval -i "del(.services.$service)" "$CONFIG_FILE"
        echo -e "${GREEN}✓ Service '$service' removed from config${NC}"
    else
        echo -e "${YELLOW}WARNING: yq not found. Cannot remove service automatically.${NC}" >&2
        echo "Please install yq or manually remove from: $CONFIG_FILE" >&2
        return 1
    fi
}

# Validate service configuration
# Usage: validate_service_config "service-name"
validate_service_config() {
    local service="$1"
    local errors=0

    # Check required fields
    local required_fields=("primary_pattern" "health_endpoint" "health_port" "version_jq_path")

    for field in "${required_fields[@]}"; do
        local value
        value=$(get_service_setting "$service" "$field")

        if [[ -z "$value" || "$value" == "null" ]]; then
            echo -e "${RED}ERROR: Missing required field '$field' for service '$service'${NC}" >&2
            errors=$((errors + 1))
        fi
    done

    # Validate health_port is a number
    local port
    port=$(get_service_setting "$service" "health_port")
    if [[ -n "$port" ]] && ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}ERROR: Invalid health_port '$port' for service '$service' (must be a number)${NC}" >&2
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Validate entire config file
validate_config() {
    validate_config_file || return 1

    local errors=0

    # Check manager settings exist
    local check_interval
    check_interval=$(get_manager_setting "check_interval")
    if [[ -z "$check_interval" || "$check_interval" == "null" ]]; then
        echo -e "${RED}ERROR: Missing manager.check_interval${NC}" >&2
        errors=$((errors + 1))
    fi

    local docker_network
    docker_network=$(get_manager_setting "docker_network")
    if [[ -z "$docker_network" || "$docker_network" == "null" ]]; then
        echo -e "${RED}ERROR: Missing manager.docker_network${NC}" >&2
        errors=$((errors + 1))
    fi

    # Validate all services
    local services
    services=$(list_services)

    if [[ -z "$services" ]]; then
        echo -e "${YELLOW}WARNING: No services configured${NC}" >&2
    else
        for service in $services; do
            if ! validate_service_config "$service"; then
                errors=$((errors + 1))
            fi
        done
    fi

    if [[ $errors -gt 0 ]]; then
        echo -e "${RED}Config validation failed with $errors error(s)${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}✓ Config validation passed${NC}"
    return 0
}

# Create default config file
# Usage: create_default_config
create_default_config() {
    local config_dir
    config_dir=$(dirname "$CONFIG_FILE")

    # Create directory if it doesn't exist
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir" || {
            echo -e "${RED}ERROR: Cannot create config directory: $config_dir${NC}" >&2
            return 1
        }
    fi

    # Don't overwrite existing config
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}WARNING: Config file already exists: $CONFIG_FILE${NC}" >&2
        return 1
    fi

    # Write default config
    cat > "$CONFIG_FILE" <<'EOF'
# Coolify Failover Manager Configuration

manager:
  # How often to check and sync failover containers (seconds)
  check_interval: 60

  # Log level: debug, info, warn, error
  log_level: info

  # Docker network where containers run
  docker_network: coolify

# Services to manage
services:
  # Example service configuration:
  # translation-api:
  #   enabled: true
  #   primary_pattern: "translation-api-eo"
  #   health_endpoint: "/health"
  #   health_port: 3000
  #   version_jq_path: ".engineVersion"
  #   traefik_config_path: "/data/coolify/proxy/dynamic/translation-service.yaml"
EOF

    echo -e "${GREEN}✓ Created default config: $CONFIG_FILE${NC}"
    return 0
}

# Export functions for use in other scripts
export -f validate_config_file
export -f get_manager_setting
export -f get_service_setting
export -f list_services
export -f is_service_enabled
export -f get_enabled_services
export -f update_service_setting
export -f add_service
export -f remove_service
export -f validate_service_config
export -f validate_config
export -f create_default_config
