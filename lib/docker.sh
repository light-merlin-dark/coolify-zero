#!/bin/bash
# docker.sh - Docker API wrapper functions

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Verify Docker is available
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}ERROR: docker command not found${NC}" >&2
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Cannot connect to Docker daemon${NC}" >&2
        echo "Are you in the docker group or running as root?" >&2
        return 1
    fi

    return 0
}

# Find container by name pattern
# Usage: find_container "translation-api-eo"
# Returns: container ID or empty string
find_container() {
    local pattern="$1"

    if [[ -z "$pattern" ]]; then
        echo -e "${RED}ERROR: Container pattern required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    # Find running containers matching the pattern
    local container_id
    container_id=$(docker ps --filter "name=$pattern" --format "{{.ID}}" | head -n 1)

    echo "$container_id"
}

# Get container name
# Usage: get_container_name "abc123"
get_container_name() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        echo -e "${RED}ERROR: Container ID required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    docker inspect "$container_id" --format '{{.Name}}' 2>/dev/null | sed 's/^\///'
}

# Get container image
# Usage: get_container_image "abc123"
get_container_image() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        echo -e "${RED}ERROR: Container ID required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    docker inspect "$container_id" --format '{{.Config.Image}}' 2>/dev/null
}

# Get container environment variables
# Usage: get_container_env "abc123"
# Returns: Array of --env "KEY=VALUE" flags suitable for docker run
get_container_env() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        echo -e "${RED}ERROR: Container ID required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    # Get env vars in format suitable for docker run
    docker inspect "$container_id" --format '{{range .Config.Env}}--env "{{.}}" {{end}}' 2>/dev/null
}

# Get container labels
# Usage: get_container_labels "abc123"
# Returns: Array of --label "key=value" flags
get_container_labels() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        echo -e "${RED}ERROR: Container ID required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    # Get labels in format suitable for docker run
    docker inspect "$container_id" --format '{{range $k, $v := .Config.Labels}}--label "{{$k}}={{$v}}" {{end}}' 2>/dev/null
}

# Get container volumes and mounts
# Usage: get_container_volumes "abc123"
# Returns: Array of -v flags suitable for docker run
get_container_volumes() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        echo -e "${RED}ERROR: Container ID required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    # Get both named volumes and bind mounts
    # Format: -v source:destination:mode
    docker inspect "$container_id" --format '{{range .Mounts}}-v "{{.Source}}:{{.Destination}}{{if .Mode}}:{{.Mode}}{{end}}" {{end}}' 2>/dev/null
}

# Check if container exists (running or stopped)
# Usage: container_exists "container-name"
container_exists() {
    local container_name="$1"

    if [[ -z "$container_name" ]]; then
        return 1
    fi

    check_docker || return 1

    if docker ps -a --filter "name=^${container_name}$" --format '{{.ID}}' | grep -q .; then
        return 0
    else
        return 1
    fi
}

# Check if container is running
# Usage: container_running "container-name"
container_running() {
    local container_name="$1"

    if [[ -z "$container_name" ]]; then
        return 1
    fi

    check_docker || return 1

    if docker ps --filter "name=^${container_name}$" --format '{{.ID}}' | grep -q .; then
        return 0
    else
        return 1
    fi
}

# Get container health status
# Usage: get_container_health "abc123"
# Returns: healthy, unhealthy, starting, none
get_container_health() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        echo "none"
        return 1
    fi

    check_docker || return 1

    local health_status
    health_status=$(docker inspect "$container_id" --format '{{.State.Health.Status}}' 2>/dev/null)

    # If no health check defined, check if running
    if [[ -z "$health_status" || "$health_status" == "<no value>" ]]; then
        local running
        running=$(docker inspect "$container_id" --format '{{.State.Running}}' 2>/dev/null)

        if [[ "$running" == "true" ]]; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "$health_status"
    fi
}

# Stop container
# Usage: stop_container "container-name"
stop_container() {
    local container_name="$1"

    if [[ -z "$container_name" ]]; then
        echo -e "${RED}ERROR: Container name required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    if container_running "$container_name"; then
        echo -e "${BLUE}Stopping container: $container_name${NC}"
        docker stop "$container_name" >/dev/null 2>&1
        return $?
    else
        # Already stopped, success
        return 0
    fi
}

# Remove container
# Usage: remove_container "container-name"
remove_container() {
    local container_name="$1"

    if [[ -z "$container_name" ]]; then
        echo -e "${RED}ERROR: Container name required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    if container_exists "$container_name"; then
        echo -e "${BLUE}Removing container: $container_name${NC}"
        docker rm -f "$container_name" >/dev/null 2>&1
        return $?
    else
        # Already removed, success
        return 0
    fi
}

# Create failover container from primary
# Usage: create_failover_container "primary-container-id" "failover-name" "network"
create_failover_container() {
    local primary_id="$1"
    local failover_name="$2"
    local network="$3"

    if [[ -z "$primary_id" ]]; then
        echo -e "${RED}ERROR: Primary container ID required${NC}" >&2
        return 1
    fi

    if [[ -z "$failover_name" ]]; then
        echo -e "${RED}ERROR: Failover container name required${NC}" >&2
        return 1
    fi

    if [[ -z "$network" ]]; then
        network="coolify"
    fi

    check_docker || return 1

    # Get primary container details
    local image
    image=$(get_container_image "$primary_id")

    if [[ -z "$image" ]]; then
        echo -e "${RED}ERROR: Cannot get image from primary container${NC}" >&2
        return 1
    fi

    local env_vars
    env_vars=$(get_container_env "$primary_id")

    local labels
    labels=$(get_container_labels "$primary_id")

    local volumes
    volumes=$(get_container_volumes "$primary_id")

    echo -e "${BLUE}Creating failover container: $failover_name${NC}"
    echo -e "${BLUE}  Image: $image${NC}"
    echo -e "${BLUE}  Network: $network${NC}"

    # Show volume info if any
    if [[ -n "$volumes" ]]; then
        local volume_count=$(echo "$volumes" | grep -o ' -v ' | wc -l | tr -d ' ')
        echo -e "${BLUE}  Volumes: $volume_count mount(s) from primary${NC}"
        echo -e "${YELLOW}  ⚠️  Sharing volumes with primary - ensure stateful data is handled correctly${NC}"
    else
        echo -e "${YELLOW}  ⚠️  No volumes detected - this should only be used for stateless services${NC}"
    fi

    # Create the failover container
    # CRITICAL: Must mount the SAME volumes as primary for stateful services!
    # Note: We use eval here because env_vars, labels, and volumes contain multiple flags
    local create_cmd="docker run -d \
        --name \"$failover_name\" \
        --network \"$network\" \
        --restart unless-stopped \
        $env_vars \
        $labels \
        $volumes \
        --label \"coolify.managed=false\" \
        \"$image\""

    if eval "$create_cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Failover container created successfully${NC}"
        return 0
    else
        echo -e "${RED}ERROR: Failed to create failover container${NC}" >&2
        return 1
    fi
}

# Recreate failover container (stop, remove, create new)
# Usage: recreate_failover "primary-container-id" "failover-name" "network"
recreate_failover() {
    local primary_id="$1"
    local failover_name="$2"
    local network="$3"

    echo -e "${BLUE}Recreating failover container: $failover_name${NC}"

    # Stop and remove old failover if exists
    stop_container "$failover_name" || true
    remove_container "$failover_name" || true

    # Wait a moment for Docker to clean up
    sleep 1

    # Create new failover
    create_failover_container "$primary_id" "$failover_name" "$network"
}

# Get container IP address on a specific network
# Usage: get_container_ip "container-name" "network-name"
get_container_ip() {
    local container_name="$1"
    local network="$2"

    if [[ -z "$container_name" ]]; then
        echo -e "${RED}ERROR: Container name required${NC}" >&2
        return 1
    fi

    if [[ -z "$network" ]]; then
        network="coolify"
    fi

    check_docker || return 1

    docker inspect "$container_name" \
        --format "{{.NetworkSettings.Networks.$network.IPAddress}}" 2>/dev/null
}

# List all containers matching a pattern
# Usage: list_containers "translation-api"
list_containers() {
    local pattern="$1"

    check_docker || return 1

    if [[ -z "$pattern" ]]; then
        docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}"
    else
        docker ps --filter "name=$pattern" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}"
    fi
}

# Get container logs
# Usage: get_container_logs "container-name" [lines]
get_container_logs() {
    local container_name="$1"
    local lines="${2:-100}"

    if [[ -z "$container_name" ]]; then
        echo -e "${RED}ERROR: Container name required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    docker logs --tail "$lines" "$container_name" 2>&1
}

# Follow container logs
# Usage: follow_container_logs "container-name"
follow_container_logs() {
    local container_name="$1"

    if [[ -z "$container_name" ]]; then
        echo -e "${RED}ERROR: Container name required${NC}" >&2
        return 1
    fi

    check_docker || return 1

    docker logs -f "$container_name" 2>&1
}

# Export functions for use in other scripts
export -f check_docker
export -f find_container
export -f get_container_name
export -f get_container_image
export -f get_container_env
export -f get_container_labels
export -f get_container_volumes
export -f container_exists
export -f container_running
export -f get_container_health
export -f stop_container
export -f remove_container
export -f create_failover_container
export -f recreate_failover
export -f get_container_ip
export -f list_containers
export -f get_container_logs
export -f follow_container_logs
