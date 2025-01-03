#!/bin/bash
set -euo pipefail

# Enhanced logging with colors
log() {
    local level="${1:-INFO}"
    local message="${2:-No message provided}"
    local color=""
    case $level in
        "INFO") color="\033[0;32m" ;;
        "WARN") color="\033[1;33m" ;;
        "ERROR") color="\033[0;31m" ;;
    esac
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}\033[0m"
}

# Check dependencies
check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    # Required commands
    local commands=(docker docker-compose curl jq)
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "ERROR" "$cmd is required but not installed"
            exit 1
        fi
    done

    # Check Docker networks
    if ! docker network inspect kopia_network >/dev/null 2>&1; then
        log "ERROR" "Kopia network not found. Is Kopia server running?"
        exit 1
    fi
}

# Check disk space with specific paths
check_disk_space() {
    log "INFO" "Checking disk space requirements..."
    
    local required_spaces=(
        "/var/lib/prometheus:10240"  # 10GB for Prometheus
        "/var/lib/grafana:1024"      # 1GB for Grafana
        "/var/log/kopia:1024"        # 1GB for logs
    )

    for space in "${required_spaces[@]}"; do
        local path="${space%%:*}"
        local required_mb="${space##*:}"
        local available_mb=$(df -m "$path" | awk 'NR==2 {print $4}')
        
        if [ "$available_mb" -lt "$required_mb" ]; then
            log "ERROR" "Insufficient space in $path. Required: ${required_mb}MB, Available: ${available_mb}MB"
            return 1
        fi
        log "INFO" "Space check passed for $path (${available_mb}MB available)"
    done
}

# Rollback function
rollback() {
    log "WARN" "Rolling back changes..."
    docker-compose -f monitoring/docker-compose.monitoring.yml down -v
    rm -rf "${PROMETHEUS_DATA_DIR:-/var/lib/prometheus}"/*
    rm -rf "${GRAFANA_DATA_DIR:-/var/lib/grafana}"/*
}

setup_prometheus() {
    log "INFO" "Setting up Prometheus monitoring..."
    
    # Check basic auth configuration
    if [ "${PROMETHEUS_BASIC_AUTH:-false}" = "true" ]; then
        if [ -z "${PROMETHEUS_AUTH_USER}" ] || [ -z "${PROMETHEUS_AUTH_PASSWORD}" ]; then
            log "ERROR" "Basic auth enabled but credentials not set"
            log "ERROR" "Please set PROMETHEUS_AUTH_USER and PROMETHEUS_AUTH_PASSWORD"
            exit 1
        fi
        log "INFO" "Basic auth enabled for Prometheus"
    fi

    # Create required directories
    sudo mkdir -p "${PROMETHEUS_DATA_DIR:-/var/lib/prometheus}"
    sudo mkdir -p "${GRAFANA_DATA_DIR:-/var/lib/grafana}"
    
    # Set permissions
    sudo chown -R "${PROM_USER:-65534}:${PROM_GROUP:-65534}" "${PROMETHEUS_DATA_DIR:-/var/lib/prometheus}"
    sudo chown -R "${GRAFANA_USER:-472}:${GRAFANA_GROUP:-472}" "${GRAFANA_DATA_DIR:-/var/lib/grafana}"
    
    # Create networks if they don't exist
    docker network inspect "${MONITORING_NETWORK_NAME:-monitoring_network}" >/dev/null 2>&1 || \
        docker network create "${MONITORING_NETWORK_NAME:-monitoring_network}"
    
    # Check if Kopia is running
    if ! docker ps | grep -q kopia-server; then
        echo "WARNING: Kopia server is not running"
        echo "Some metrics may not be available"
    fi

    # Check disk space
    MIN_SPACE=1000000  # 1GB
    available=$(df -k "${PROMETHEUS_DATA_DIR:-/var/lib/prometheus}" | awk 'NR==2 {print $4}')
    if [ "$available" -lt "$MIN_SPACE" ]; then
        echo "WARNING: Low disk space for Prometheus data"
    fi
    
    # Deploy monitoring stack
    docker-compose -f monitoring/docker-compose.monitoring.yml up -d
    
    echo "Prometheus monitoring setup completed"
}

setup_zabbix() {
    log "INFO" "Setting up Zabbix monitoring..."
    
    if [ "${ZABBIX_EXTERNAL:-false}" = "true" ]; then
        log "INFO" "Using external Zabbix server at ${ZABBIX_SERVER_HOST}"
        
        # Check Zabbix server availability
        if ! ping -c 1 "${ZABBIX_SERVER_HOST}" &>/dev/null; then
            log "ERROR" "Cannot reach Zabbix server at ${ZABBIX_SERVER_HOST}"
            exit 1
        fi
        
        # Setup agent and scripts only
        setup_zabbix_agent
        setup_zabbix_scripts
    else
        # Full local installation
        (cd monitoring/zabbix && ./setup.sh)
    fi
}

setup_zabbix_agent() {
    log "INFO" "Setting up Zabbix agent..."
    
    # Create script directories
    mkdir -p "${ZABBIX_EXTERNAL_SCRIPTS}"
    chmod 755 "${ZABBIX_EXTERNAL_SCRIPTS}"
    
    # Copy agent configuration
    mkdir -p "${ZABBIX_AGENT_CONFIG}"
    cp monitoring/zabbix/config/zabbix_agentd.d/* "${ZABBIX_AGENT_CONFIG}/"
    
    # Start agent only
    docker-compose -f monitoring/docker-compose.monitoring.yml up -d zabbix-agent
}

setup_zabbix_scripts() {
    log "INFO" "Setting up Zabbix monitoring scripts..."
    
    # Copy monitoring scripts
    cp monitoring/zabbix/scripts/* "${ZABBIX_EXTERNAL_SCRIPTS}/"
    chmod +x "${ZABBIX_EXTERNAL_SCRIPTS}"/*
    
    log "INFO" "Zabbix scripts installed in ${ZABBIX_EXTERNAL_SCRIPTS}"
}

# Generate Grafana API key
generate_grafana_api_key() {
    log "INFO" "Generating Grafana API key..."
    
    # Wait for Grafana to be ready
    local max_retries=30
    local retry_delay=5
    local grafana_url="http://localhost:${GRAFANA_PORT:-3000}"
    
    for ((i=1; i<=max_retries; i++)); do
        if curl -s "${grafana_url}/api/health" | grep -q "ok"; then
            log "INFO" "Grafana is ready"
            break
        fi
        if [ $i -eq $max_retries ]; then
            log "ERROR" "Grafana not ready after ${max_retries} attempts"
            exit 1
        fi
        log "INFO" "Waiting for Grafana to be ready (attempt $i)..."
        sleep $retry_delay
    done

    # Generate API key
    local api_key=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
        "${grafana_url}/api/auth/keys" \
        -d '{
            "name": "kopia-monitoring",
            "role": "Admin",
            "secondsToLive": 315360000
        }' | jq -r '.key')

    if [ -z "$api_key" ] || [ "$api_key" = "null" ]; then
        log "ERROR" "Failed to generate Grafana API key"
        exit 1
    fi

    # Save API key to file
    local api_key_file="${KOPIA_BASE_DIR}/grafana_api_key"
    echo "${api_key}" > "${api_key_file}"
    chmod 600 "${api_key_file}"

    # Update .env file
    if grep -q "^GRAFANA_API_KEY=" .env; then
        sed -i "s|^GRAFANA_API_KEY=.*|GRAFANA_API_KEY=${api_key}|" .env
    else
        echo "GRAFANA_API_KEY=${api_key}" >> .env
    fi

    # Print key information
    log "INFO" "Generated Grafana API key:"
    log "INFO" "Key has been saved to: ${api_key_file}"
    log "INFO" "Key has been added to .env file"
    log "INFO" "Key value (save this somewhere safe):"
    echo "----------------------------------------"
    echo "${api_key}"
    echo "----------------------------------------"
    log "INFO" "This key will be valid for 10 years"
}

setup_external_monitoring() {
    log "INFO" "Setting up external monitoring integration..."
    
    # Validate external monitoring configuration
    local external_config_valid=true
    
    # Check Grafana configuration
    if [ "${GRAFANA_EXTERNAL:-false}" = "true" ]; then
        log "INFO" "Validating external Grafana configuration..."
        
        # Required variables
        local grafana_vars=(
            "GRAFANA_URL"
            "GRAFANA_API_KEY"
        )
        
        for var in "${grafana_vars[@]}"; do
            if [ -z "${!var}" ]; then
                log "ERROR" "Required variable $var is not set for external Grafana"
                external_config_valid=false
            fi
        done
        
        # Test Grafana connectivity
        if ! curl -sf -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
             "${GRAFANA_URL}/api/health" &>/dev/null; then
            log "ERROR" "Cannot connect to Grafana at ${GRAFANA_URL} with provided API key"
            external_config_valid=false
        else
            log "INFO" "Successfully connected to external Grafana at ${GRAFANA_URL}"
            
            # Configure Prometheus datasource in Grafana
            log "INFO" "Configuring Prometheus datasource in Grafana..."
            curl -sf -X POST \
                -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
                -H "Content-Type: application/json" \
                "${GRAFANA_URL}/api/datasources" \
                -d '{
                    "name": "Kopia-Prometheus",
                    "type": "prometheus",
                    "url": "http://'${KOPIA_SERVER_IP}':'${PROMETHEUS_UI_PORT}'",
                    "access": "proxy",
                    "basicAuth": false
                }' || log "WARN" "Failed to configure Prometheus datasource"
        fi
    fi
    
    # Check Zabbix configuration
    if [ "${ZABBIX_EXTERNAL:-false}" = "true" ]; then
        log "INFO" "Validating external Zabbix configuration..."
        
        # Required variables
        local zabbix_vars=(
            "ZABBIX_URL"
            "ZABBIX_SERVER_HOST"
            "ZABBIX_USERNAME"
            "ZABBIX_PASSWORD"
        )
        
        for var in "${zabbix_vars[@]}"; do
            if [ -z "${!var}" ]; then
                log "ERROR" "Required variable $var is not set for external Zabbix"
                external_config_valid=false
            fi
        done
        
        # Test Zabbix connectivity
        if ! ping -c 1 "${ZABBIX_SERVER_HOST}" &>/dev/null; then
            log "ERROR" "Cannot reach Zabbix server at ${ZABBIX_SERVER_HOST}"
            external_config_valid=false
        else
            log "INFO" "Successfully reached Zabbix server at ${ZABBIX_SERVER_HOST}"
            
            # Test Zabbix API
            if ! curl -sf -H "Content-Type: application/json" \
                 -d '{"jsonrpc":"2.0","method":"apiinfo.version","id":1}' \
                 "${ZABBIX_URL}" &>/dev/null; then
                log "ERROR" "Cannot connect to Zabbix API at ${ZABBIX_URL}"
                external_config_valid=false
            else
                log "INFO" "Successfully connected to Zabbix API"
            fi
        fi
    fi
    
    # Exit if any external configuration is invalid
    if [ "$external_config_valid" = "false" ]; then
        log "ERROR" "External monitoring configuration validation failed"
        exit 1
    fi
    
    # Deploy appropriate monitoring components
    if [ "${GRAFANA_EXTERNAL:-false}" = "true" ] && [ "${ZABBIX_EXTERNAL:-false}" = "true" ]; then
        log "INFO" "Deploying monitoring stack with external Grafana and Zabbix..."
        docker-compose -f monitoring/docker-compose.monitoring.yml \
            --profile prometheus up -d
    elif [ "${GRAFANA_EXTERNAL:-false}" = "true" ]; then
        log "INFO" "Deploying monitoring stack with external Grafana..."
        docker-compose -f monitoring/docker-compose.monitoring.yml \
            --profile prometheus up -d
    elif [ "${ZABBIX_EXTERNAL:-false}" = "true" ]; then
        log "INFO" "Deploying monitoring stack with external Zabbix..."
        docker-compose -f monitoring/docker-compose.monitoring.yml \
            --profile prometheus --profile local-grafana up -d
    fi
    
    log "INFO" "External monitoring integration completed"
}

# Check Grafana configuration
determine_monitoring_profile() {
    local profile=""
    
    # Check Grafana configuration
    local grafana_mode="none"
    if [ "${GRAFANA_ENABLED:-false}" = "true" ]; then
        if [ "${GRAFANA_EXTERNAL:-false}" = "true" ]; then
            grafana_mode="external"
        else
            grafana_mode="local"
        fi
    fi
    
    # Check Zabbix configuration
    local zabbix_mode="none"
    if [ "${ZABBIX_ENABLED:-false}" = "true" ]; then
        if [ "${ZABBIX_EXTERNAL:-false}" = "true" ]; then
            zabbix_mode="external"
        else
            zabbix_mode="local"
        fi
    fi
    
    # Determine required profile based on combination
    case "${grafana_mode}:${zabbix_mode}" in
        "none:none")
            profile="base-metrics"
            ;;
        "local:none")
            profile="grafana-local"
            ;;
        "none:local")
            profile="zabbix-local"  
            ;;
        "local:local")
            profile="full-stack"
            ;;
        "external:external")
            profile="grafana-zabbix-external"
            ;;
        "external:local")
            profile="grafana-external,zabbix-local"
            ;;
        "local:external")
            profile="grafana-local,zabbix-external"
            ;;
        *)
            log "ERROR" "Invalid monitoring configuration"
            exit 1
            ;;
    esac
    
    echo "$profile"
}

# Check external services
verify_external_services() {
    if [ "${GRAFANA_EXTERNAL:-false}" = "true" ]; then
        verify_external_grafana
    fi
    if [ "${ZABBIX_EXTERNAL:-false}" = "true" ]; then
        verify_external_zabbix
    fi
}

# Deploy monitoring
deploy_monitoring() {
    local profile=$(determine_monitoring_profile)
    
    log "INFO" "Deploying monitoring with profile: ${profile}"
    
    # Start with determined profile
    if [[ "$profile" == *","* ]]; then
        # If multiple profiles, split them
        IFS=',' read -ra PROFILES <<< "$profile"
        for p in "${PROFILES[@]}"; do
            docker-compose -f monitoring/docker-compose.monitoring.yml \
                --profile "$p" up -d
        done
    else
        docker-compose -f monitoring/docker-compose.monitoring.yml \
            --profile "$profile" up -d
    fi
}

# Main installation function
main() {
    log "INFO" "Starting monitoring setup..."
    
    # Checks
    check_dependencies
    check_system_requirements
    validate_environment
    
    # Check external services if needed
    verify_external_services
    
    # Deploy monitoring
    deploy_monitoring
    
    # Configure integrations
    if [ "${GRAFANA_ENABLED:-false}" = "true" ]; then
        configure_grafana_integration
    fi
    if [ "${ZABBIX_ENABLED:-false}" = "true" ]; then
        configure_zabbix_integration
    fi
    
    log "INFO" "Monitoring setup completed"
}

setup_monitoring() {
    log "INFO" "Setting up monitoring..."

    # Validate monitoring variables
    if [ "${GRAFANA_EXTERNAL:-false}" = "true" ]; then
        local required_grafana_vars=(
            "GRAFANA_URL"
            "GRAFANA_API_KEY"
        )
        
        for var in "${required_grafana_vars[@]}"; do
            if [ -z "${!var}" ]; then
                log "ERROR" "Required variable $var is not set for external Grafana"
                exit 1
            fi
        done
        
        # Check Grafana availability
        if ! curl -sf "${GRAFANA_URL}/api/health" &>/dev/null; then
            log "ERROR" "Cannot reach Grafana at ${GRAFANA_URL}"
            exit 1
        fi
        log "INFO" "External Grafana is accessible at ${GRAFANA_URL}"
        
        # Verify API key works
        if ! curl -sf -H "Authorization: Bearer ${GRAFANA_API_KEY}" "${GRAFANA_URL}/api/health" &>/dev/null; then
            log "ERROR" "Invalid Grafana API key"
            exit 1
        fi
        log "INFO" "Grafana API key is valid"
    fi

    if [ "${ZABBIX_EXTERNAL:-false}" = "true" ]; then
        local required_zabbix_vars=(
            "ZABBIX_URL"
            "ZABBIX_SERVER_HOST"
            "ZABBIX_USERNAME"
            "ZABBIX_PASSWORD"
        )
        
        for var in "${required_zabbix_vars[@]}"; do
            if [ -z "${!var}" ]; then
                log "ERROR" "Required variable $var is not set for external Zabbix"
                exit 1
            fi
        done
        
        # Check Zabbix API availability
        if ! curl -sf -H "Content-Type: application/json" \
             -d '{"jsonrpc":"2.0","method":"apiinfo.version","id":1}' \
             "${ZABBIX_URL}" &>/dev/null; then
            log "ERROR" "Cannot reach Zabbix API at ${ZABBIX_URL}"
            exit 1
        fi
        log "INFO" "External Zabbix API is accessible at ${ZABBIX_URL}"
        
        # Check Zabbix server connectivity
        if ! ping -c 1 "${ZABBIX_SERVER_HOST}" &>/dev/null; then
            log "ERROR" "Cannot reach Zabbix server at ${ZABBIX_SERVER_HOST}"
            exit 1
        fi
        log "INFO" "Zabbix server is accessible at ${ZABBIX_SERVER_HOST}"
    fi

    # Deploy monitoring stack based on configuration
    if [ "${GRAFANA_EXTERNAL:-false}" = "true" ] && [ "${ZABBIX_EXTERNAL:-false}" = "true" ]; then
        log "INFO" "Deploying monitoring stack with external Grafana and Zabbix..."
        docker-compose -f monitoring/docker-compose.monitoring.yml \
            --profile prometheus up -d
    elif [ "${GRAFANA_EXTERNAL:-false}" = "true" ]; then
        log "INFO" "Deploying monitoring stack with external Grafana..."
        docker-compose -f monitoring/docker-compose.monitoring.yml \
            --profile prometheus up -d
    elif [ "${ZABBIX_EXTERNAL:-false}" = "true" ]; then
        log "INFO" "Deploying monitoring stack with external Zabbix..."
        docker-compose -f monitoring/docker-compose.monitoring.yml \
            --profile prometheus --profile local-grafana up -d
    else
        log "INFO" "Deploying full monitoring stack..."
        docker-compose -f monitoring/docker-compose.monitoring.yml \
            --profile all up -d
    fi
}

# Run main with error handling
trap 'log "ERROR" "Script failed on line $LINENO"' ERR
main "$@"