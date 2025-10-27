#!/bin/bash
# health.sh - Health check and version comparison logic

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default health check settings
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-5}"
HEALTH_RETRIES="${HEALTH_RETRIES:-3}"
HEALTH_RETRY_DELAY="${HEALTH_RETRY_DELAY:-2}"

# Verify required tools
check_health_tools() {
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}ERROR: curl command not found${NC}" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}ERROR: jq command not found${NC}" >&2
        return 1
    fi

    return 0
}

# HTTP health check
# Usage: http_health_check "container-name" "endpoint" "port" [network]
# Returns: 0 if healthy, 1 if unhealthy
http_health_check() {
    local container_name="$1"
    local endpoint="$2"
    local port="$3"
    local network="${4:-coolify}"

    if [[ -z "$container_name" || -z "$endpoint" || -z "$port" ]]; then
        echo -e "${RED}ERROR: http_health_check requires container_name, endpoint, and port${NC}" >&2
        return 1
    fi

    # Use docker exec to run curl inside the container (uses localhost)
    # This avoids Docker DNS issues when running from the host
    local http_code
    http_code=$(docker exec "$container_name" curl -s -o /dev/null -w "%{http_code}" \
        --max-time "$HEALTH_TIMEOUT" \
        --connect-timeout "$HEALTH_TIMEOUT" \
        "http://localhost:${port}${endpoint}" 2>/dev/null || echo "000")

    # Check if HTTP status is 2xx
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    else
        return 1
    fi
}

# HTTP health check with retries
# Usage: http_health_check_retry "container-name" "endpoint" "port" [network]
http_health_check_retry() {
    local container_name="$1"
    local endpoint="$2"
    local port="$3"
    local network="${4:-coolify}"

    local retries=$HEALTH_RETRIES
    local attempt=1

    while [[ $attempt -le $retries ]]; do
        if http_health_check "$container_name" "$endpoint" "$port" "$network"; then
            return 0
        fi

        if [[ $attempt -lt $retries ]]; then
            sleep "$HEALTH_RETRY_DELAY"
        fi

        attempt=$((attempt + 1))
    done

    # All retries failed
    return 1
}

# Get version from health endpoint
# Usage: get_version "container-name" "endpoint" "port" "jq-path" [network]
# Returns: version string or empty
get_version() {
    local container_name="$1"
    local endpoint="$2"
    local port="$3"
    local jq_path="$4"
    local network="${5:-coolify}"

    if [[ -z "$container_name" || -z "$endpoint" || -z "$port" || -z "$jq_path" ]]; then
        echo -e "${RED}ERROR: get_version requires container_name, endpoint, port, and jq_path${NC}" >&2
        return 1
    fi

    # Use docker exec to run curl inside the container
    local version
    version=$(docker exec "$container_name" curl -s --max-time "$HEALTH_TIMEOUT" \
        "http://localhost:${port}${endpoint}" 2>/dev/null | jq -r "$jq_path" 2>/dev/null)

    # Check if version is valid (not null or empty)
    if [[ -z "$version" || "$version" == "null" ]]; then
        return 1
    fi

    echo "$version"
}

# Get version with retries
# Usage: get_version_retry "container-name" "endpoint" "port" "jq-path" [network]
get_version_retry() {
    local container_name="$1"
    local endpoint="$2"
    local port="$3"
    local jq_path="$4"
    local network="${5:-coolify}"

    local retries=$HEALTH_RETRIES
    local attempt=1

    while [[ $attempt -le $retries ]]; do
        local version
        version=$(get_version "$container_name" "$endpoint" "$port" "$jq_path" "$network")

        if [[ -n "$version" && "$version" != "null" ]]; then
            echo "$version"
            return 0
        fi

        if [[ $attempt -lt $retries ]]; then
            sleep "$HEALTH_RETRY_DELAY"
        fi

        attempt=$((attempt + 1))
    done

    # All retries failed
    return 1
}

# Compare two versions
# Usage: versions_match "v1.4.84" "v1.4.84"
# Returns: 0 if match, 1 if different
versions_match() {
    local version1="$1"
    local version2="$2"

    # Handle empty versions
    if [[ -z "$version1" || -z "$version2" ]]; then
        return 1
    fi

    # Handle null versions
    if [[ "$version1" == "null" || "$version2" == "null" ]]; then
        return 1
    fi

    # Simple string comparison
    if [[ "$version1" == "$version2" ]]; then
        return 0
    else
        return 1
    fi
}

# Check if container is healthy and get version
# Usage: check_container_health_and_version "container-name" "endpoint" "port" "jq-path"
# Returns: version string if healthy, empty if unhealthy
check_container_health_and_version() {
    local container_name="$1"
    local endpoint="$2"
    local port="$3"
    local jq_path="$4"

    # First check if container is healthy
    if ! http_health_check_retry "$container_name" "$endpoint" "$port"; then
        return 1
    fi

    # If healthy, get version
    get_version_retry "$container_name" "$endpoint" "$port" "$jq_path"
}

# Wait for container to become healthy
# Usage: wait_for_healthy "container-name" "endpoint" "port" [timeout-seconds]
wait_for_healthy() {
    local container_name="$1"
    local endpoint="$2"
    local port="$3"
    local timeout="${4:-60}"

    local elapsed=0
    local interval=5

    echo -e "${BLUE}Waiting for $container_name to become healthy...${NC}"

    while [[ $elapsed -lt $timeout ]]; do
        if http_health_check "$container_name" "$endpoint" "$port"; then
            echo -e "${GREEN}✓ Container is healthy${NC}"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))

        if [[ $elapsed -lt $timeout ]]; then
            echo -e "${YELLOW}Still waiting... (${elapsed}s/${timeout}s)${NC}"
        fi
    done

    echo -e "${RED}✗ Container failed to become healthy within ${timeout}s${NC}" >&2
    return 1
}

# Get full health status with version
# Usage: get_health_status "container-name" "endpoint" "port" "jq-path"
# Prints: JSON with health and version info
get_health_status() {
    local container_name="$1"
    local endpoint="$2"
    local port="$3"
    local jq_path="$4"

    local healthy="false"
    local version=""

    if http_health_check_retry "$container_name" "$endpoint" "$port"; then
        healthy="true"
        version=$(get_version_retry "$container_name" "$endpoint" "$port" "$jq_path" 2>/dev/null || echo "unknown")
    fi

    # Output as JSON
    jq -n \
        --arg container "$container_name" \
        --arg healthy "$healthy" \
        --arg version "$version" \
        '{container: $container, healthy: ($healthy == "true"), version: $version}'
}

# Check if service needs sync
# Usage: needs_sync "primary-name" "failover-name" "endpoint" "port" "jq-path"
# Returns: 0 if sync needed, 1 if in sync or cannot determine
needs_sync() {
    local primary_name="$1"
    local failover_name="$2"
    local endpoint="$3"
    local port="$4"
    local jq_path="$5"

    # Check if primary is healthy
    if ! http_health_check_retry "$primary_name" "$endpoint" "$port"; then
        # Primary unhealthy, don't sync (deployment in progress)
        return 1
    fi

    # Get primary version
    local primary_version
    primary_version=$(get_version_retry "$primary_name" "$endpoint" "$port" "$jq_path")

    if [[ -z "$primary_version" || "$primary_version" == "null" ]]; then
        # Cannot get primary version, skip sync
        return 1
    fi

    # Check if failover exists and is running
    # (This would need docker.sh functions, but we're keeping libs independent)
    # For now, just try to get failover version

    # Get failover version
    local failover_version
    failover_version=$(get_version "$failover_name" "$endpoint" "$port" "$jq_path" 2>/dev/null)

    # If failover doesn't exist or versions don't match, needs sync
    if [[ -z "$failover_version" || "$failover_version" == "null" ]]; then
        return 0  # Needs sync (failover doesn't exist or no version)
    fi

    # Compare versions
    if versions_match "$primary_version" "$failover_version"; then
        return 1  # In sync
    else
        return 0  # Needs sync
    fi
}

# Pretty print health status
# Usage: print_health_status "container-name" "endpoint" "port" "jq-path"
print_health_status() {
    local container_name="$1"
    local endpoint="$2"
    local port="$3"
    local jq_path="$4"

    echo -e "${BLUE}Checking health: $container_name${NC}"

    if http_health_check "$container_name" "$endpoint" "$port"; then
        local version
        version=$(get_version "$container_name" "$endpoint" "$port" "$jq_path" 2>/dev/null || echo "unknown")
        echo -e "${GREEN}  ✓ Healthy${NC}"
        echo -e "  Version: $version"
    else
        echo -e "${RED}  ✗ Unhealthy${NC}"
    fi
}

# Export functions for use in other scripts
export -f check_health_tools
export -f http_health_check
export -f http_health_check_retry
export -f get_version
export -f get_version_retry
export -f versions_match
export -f check_container_health_and_version
export -f wait_for_healthy
export -f get_health_status
export -f needs_sync
export -f print_health_status
