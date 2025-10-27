#!/bin/bash
# coolify-zero.sh - Main daemon for managing failover containers
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

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global state
RUNNING=true
CHECK_INTERVAL=60
LOG_LEVEL="info"
DOCKER_NETWORK="coolify"

# Log levels: debug=0, info=1, warn=2, error=3
declare -A LOG_LEVELS=([debug]=0 [info]=1 [warn]=2 [error]=3)

# Get timestamp for logging
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Logging function
# Usage: log "level" "message"
log() {
    local level="$1"
    shift
    local message="$*"

    local current_level_num=${LOG_LEVELS[$LOG_LEVEL]:-1}
    local msg_level_num=${LOG_LEVELS[$level]:-1}

    # Only log if message level >= current log level
    if [[ $msg_level_num -ge $current_level_num ]]; then
        local color=""
        case "$level" in
            debug) color="$CYAN" ;;
            info)  color="$GREEN" ;;
            warn)  color="$YELLOW" ;;
            error) color="$RED" ;;
        esac

        echo -e "$(timestamp) ${color}[${level^^}]${NC} $message"
    fi
}

# Load configuration
load_config() {
    log "info" "Loading configuration from $CONFIG_FILE"

    if ! validate_config_file; then
        log "error" "Config file not found or invalid"
        exit 1
    fi

    # Load manager settings
    CHECK_INTERVAL=$(get_manager_setting "check_interval")
    LOG_LEVEL=$(get_manager_setting "log_level")
    DOCKER_NETWORK=$(get_manager_setting "docker_network")

    # Set defaults if not specified
    CHECK_INTERVAL=${CHECK_INTERVAL:-60}
    LOG_LEVEL=${LOG_LEVEL:-info}
    DOCKER_NETWORK=${DOCKER_NETWORK:-coolify}

    log "info" "Configuration loaded:"
    log "info" "  Check interval: ${CHECK_INTERVAL}s"
    log "info" "  Log level: $LOG_LEVEL"
    log "info" "  Docker network: $DOCKER_NETWORK"
}

# Process a single service
# Usage: process_service "service-name"
process_service() {
    local service="$1"

    log "debug" "Processing service: $service"

    # Check if service is enabled
    if ! is_service_enabled "$service"; then
        log "debug" "Service $service is disabled, skipping"
        return 0
    fi

    # Get service configuration
    local primary_pattern
    local health_endpoint
    local health_port
    local version_jq_path

    primary_pattern=$(get_service_setting "$service" "primary_pattern")
    health_endpoint=$(get_service_setting "$service" "health_endpoint")
    health_port=$(get_service_setting "$service" "health_port")
    version_jq_path=$(get_service_setting "$service" "version_jq_path")

    # Validate configuration (version_jq_path is optional)
    if [[ -z "$primary_pattern" || -z "$health_endpoint" || -z "$health_port" ]]; then
        log "error" "Incomplete configuration for service: $service (requires primary_pattern, health_endpoint, health_port)"
        return 1
    fi

    # Find primary container
    local primary_id
    primary_id=$(find_container "$primary_pattern")

    if [[ -z "$primary_id" ]]; then
        log "warn" "Primary container not found for service: $service (pattern: $primary_pattern)"
        return 1
    fi

    local primary_name
    primary_name=$(get_container_name "$primary_id")

    log "debug" "Found primary: $primary_name ($primary_id)"

    # Check primary health
    if ! http_health_check "$primary_name" "$health_endpoint" "$health_port"; then
        log "info" "Primary $primary_name is unhealthy (deployment in progress?), skipping sync"
        return 0
    fi

    log "debug" "Primary $primary_name is healthy"

    # Check failover container
    local failover_name="failover-${service}"
    local needs_sync=false
    local sync_reason=""
    local comparison_method=""

    # Check if failover exists
    if ! container_exists "$failover_name"; then
        log "info" "Failover container $failover_name does not exist, will create"
        needs_sync=true
        sync_reason="failover doesn't exist"
    else
        # Failover exists, determine if sync is needed
        # Try version comparison first (if configured)
        if [[ -n "$version_jq_path" ]]; then
            log "debug" "Attempting version comparison (using $version_jq_path)"

            local primary_version
            primary_version=$(get_version "$primary_name" "$health_endpoint" "$health_port" "$version_jq_path" 2>/dev/null)

            local failover_version
            failover_version=$(get_version "$failover_name" "$health_endpoint" "$health_port" "$version_jq_path" 2>/dev/null)

            if [[ -n "$primary_version" && "$primary_version" != "null" && -n "$failover_version" && "$failover_version" != "null" ]]; then
                # Both versions retrieved successfully
                comparison_method="version"
                log "debug" "Primary version: $primary_version"
                log "debug" "Failover version: $failover_version"

                if ! versions_match "$primary_version" "$failover_version"; then
                    needs_sync=true
                    sync_reason="version mismatch ($failover_version -> $primary_version)"
                else
                    log "debug" "Service $service is in sync (version: $primary_version)"
                fi
            else
                log "debug" "Version comparison failed (primary: ${primary_version:-null}, failover: ${failover_version:-null}), falling back to image comparison"
                comparison_method="image"
            fi
        else
            log "debug" "No version_jq_path configured, using image comparison"
            comparison_method="image"
        fi

        # Fall back to image comparison if version comparison wasn't possible
        if [[ "$comparison_method" == "image" ]]; then
            log "debug" "Comparing container images"

            if images_match "$primary_name" "$failover_name"; then
                log "debug" "Service $service is in sync (same image)"
            else
                needs_sync=true
                local primary_image_digest
                local failover_image_digest
                primary_image_digest=$(get_container_image_digest "$primary_name")
                failover_image_digest=$(get_container_image_digest "$failover_name")
                sync_reason="image mismatch (${failover_image_digest:0:12}... -> ${primary_image_digest:0:12}...)"
            fi
        fi
    fi

    # Perform sync if needed
    if [[ "$needs_sync" == "false" ]]; then
        return 0
    fi

    # Sync needed
    log "info" "Syncing failover for $service: $sync_reason"
    log "info" "  Primary: $primary_name"
    log "info" "  Failover: $failover_name"

    # Recreate failover
    if recreate_failover "$primary_id" "$failover_name" "$DOCKER_NETWORK"; then
        log "info" "✓ Failover sync complete for $service"

        # Wait a moment for container to start
        sleep 2

        # Verify failover health
        if http_health_check "$failover_name" "$health_endpoint" "$health_port"; then
            local status_msg="✓ Failover $failover_name is healthy"

            # Add version/image info if available
            if [[ -n "$version_jq_path" ]]; then
                local new_version
                new_version=$(get_version "$failover_name" "$health_endpoint" "$health_port" "$version_jq_path" 2>/dev/null || echo "unknown")
                if [[ -n "$new_version" && "$new_version" != "unknown" && "$new_version" != "null" ]]; then
                    status_msg="$status_msg (version: $new_version)"
                fi
            fi

            log "info" "$status_msg"
        else
            log "warn" "⚠ Failover $failover_name created but not healthy yet (may need more time)"
        fi
    else
        log "error" "✗ Failed to recreate failover for $service"
        return 1
    fi

    return 0
}

# Main processing loop
main_loop() {
    log "info" "Starting main processing loop"

    while $RUNNING; do
        local loop_start
        loop_start=$(date +%s)

        log "debug" "Starting check cycle"

        # Get all enabled services
        local services
        services=$(get_enabled_services)

        if [[ -z "$services" ]]; then
            log "debug" "No enabled services found"
        else
            log "info" "Checking services: $services"

            # Process each service
            for service in $services; do
                # Continue on error (don't let one service failure stop others)
                process_service "$service" || log "warn" "Failed to process service: $service"
            done
        fi

        local loop_end
        loop_end=$(date +%s)
        local loop_duration=$((loop_end - loop_start))

        log "debug" "Check cycle completed in ${loop_duration}s"

        # Sleep for remaining interval
        local sleep_time=$((CHECK_INTERVAL - loop_duration))
        if [[ $sleep_time -gt 0 ]]; then
            log "debug" "Sleeping for ${sleep_time}s until next check"
            sleep "$sleep_time"
        else
            log "warn" "Check cycle took longer than interval (${loop_duration}s > ${CHECK_INTERVAL}s)"
        fi
    done

    log "info" "Main loop stopped"
}

# Handle shutdown signal
shutdown() {
    log "info" "Received shutdown signal"
    RUNNING=false
}

# Trap signals for graceful shutdown
trap shutdown SIGTERM SIGINT

# Main entry point
main() {
    log "info" "=== Coolify Zero Starting ==="
    log "info" "Version: 1.0.0"

    # Check prerequisites
    if ! check_docker; then
        log "error" "Docker not available, exiting"
        exit 1
    fi

    if ! check_health_tools; then
        log "error" "Required tools not available (curl, jq), exiting"
        exit 1
    fi

    # Load configuration
    load_config

    # Validate configuration
    if ! validate_config; then
        log "error" "Configuration validation failed, exiting"
        exit 1
    fi

    log "info" "All prerequisites met, starting manager"

    # Start main loop
    main_loop

    log "info" "=== Coolify Zero Stopped ==="
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
