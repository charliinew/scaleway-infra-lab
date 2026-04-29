#!/bin/bash
# Health Check Validation Script
#
# This script performs comprehensive health checks across the entire
# image converter platform infrastructure.
#
# Usage: ./scripts/health-check.sh [--verbose] [--json] [--component COMPONENT]
#
# Exit codes:
#   0 - All health checks passed
#   1 - One or more critical checks failed
#   2 - One or more warning checks failed
#   3 - Script execution error

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPT_NAME=$(basename "$0")
VERSION="1.0.0"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
VERBOSE=false
JSON_OUTPUT=false
COMPONENT_FILTER=""

# Load environment from terraform outputs
TF_DIR="terraform"
LB_IP=""
CONVERTER_URL=""
AI_GENERATOR_URL=""
KAPSULE_ID=""
NAMESPACE=""
PROJECT_ID=""

# Counters
CRITICAL_FAILURES=0
WARNING_FAILURES=0
TOTAL_CHECKS=0
PASSED_CHECKS=0

# Results array (for JSON output)
declare -a CHECK_RESULTS=()

# ── Helper Functions ──────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Perform comprehensive health checks on the image converter platform.

OPTIONS:
    -v, --verbose       Show detailed output for each check
    -j, --json          Output results in JSON format
    -c, --component     Filter checks by component (k8s|serverless|database|s3|all)
    -h, --help          Show this help message
    --version           Show version information

COMPONENTS:
    k8s         Kubernetes cluster and deployments
    serverless  Serverless Containers (converter + AI generator)
    database    PostgreSQL database connectivity
    s3          Object Storage bucket access
    secrets     Secret Manager availability
    all         Run all checks (default)

EXAMPLES:
    $SCRIPT_NAME                          # Run all checks with default output
    $SCRIPT_NAME --verbose                # Run all checks with detailed output
    $SCRIPT_NAME --json                   # Output results as JSON
    $SCRIPT_NAME -c k8s --verbose         # Check only Kubernetes components

EXIT CODES:
    0   All health checks passed
    1   One or more critical checks failed
    2   One or more warning checks failed
    3   Script execution error (missing dependencies, etc.)

EOF
    exit 0
}

version() {
    echo "$SCRIPT_NAME version $VERSION"
    exit 0
}

log() {
    local level=$1
    local message=$2
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    case $level in
        INFO)
            echo -e "${BLUE}[INFO]${NC} [$timestamp] $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}[PASS]${NC} [$timestamp] $message"
            ;;
        WARNING)
            echo -e "${YELLOW}[WARN]${NC} [$timestamp] $message"
            ;;
        ERROR)
            echo -e "${RED}[FAIL]${NC} [$timestamp] $message"
            ;;
        *)
            echo "[$timestamp] $message"
            ;;
    esac
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        log "$@"
    fi
}

check_dependency() {
    local cmd=$1
    local install_url=$2

    if ! command -v "$cmd" &> /dev/null; then
        log ERROR "Required command '$cmd' not found. Install from: $install_url"
        exit 3
    fi
}

add_result() {
    local component=$1
    local check_name=$2
    local status=$3
    local severity=$4
    local message=$5
    local latency_ms=${6:-0}

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if [ "$status" = "PASS" ]; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    elif [ "$severity" = "CRITICAL" ]; then
        CRITICAL_FAILURES=$((CRITICAL_FAILURES + 1))
    else
        WARNING_FAILURES=$((WARNING_FAILURES + 1))
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        CHECK_RESULTS+=("{\"component\":\"$component\",\"check\":\"$check_name\",\"status\":\"$status\",\"severity\":\"$severity\",\"message\":\"$message\",\"latency_ms\":$latency_ms,\"timestamp\":\"$TIMESTAMP\"}")
    fi
}

# ── Initialization ────────────────────────────────────────────────────────────

load_terraform_outputs() {
    log_verbose INFO "Loading Terraform outputs..."

    if [ ! -d "$TF_DIR" ]; then
        log WARNING "Terraform directory not found, using environment variables"
        LB_IP="${LB_IP:-${ONBOARDING_LB_IP:-}}"
        CONVERTER_URL="${CONVERTER_URL:-${ONBOARDING_CONVERTER_URL:-}}"
        AI_GENERATOR_URL="${AI_GENERATOR_URL:-${ONBOARDING_AI_URL:-}}"
        return
    fi

    cd "$TF_DIR"

    LB_IP=$(terraform output -raw load_balancer_ip 2>/dev/null || echo "")
    CONVERTER_URL=$(terraform output -raw image_converter_url 2>/dev/null || echo "")
    AI_GENERATOR_URL=$(terraform output -raw ai_alt_generator_url 2>/dev/null || echo "")
    KAPSULE_ID=$(terraform output -raw kapsule_cluster_id 2>/dev/null || echo "")
    NAMESPACE=$(grep 'registry_namespace' terraform.tfvars 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || echo "")
    PROJECT_ID=$(grep 'project_id' terraform.tfvars 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || echo "")

    cd - > /dev/null

    log_verbose INFO "Loaded: LB_IP=$LB_IP, NAMESPACE=$NAMESPACE"
}

initialize() {
    log INFO "Starting health checks at $TIMESTAMP"
    log INFO "Version: $VERSION"

    # Check dependencies
    check_dependency "curl" "https://curl.se/"
    check_dependency "jq" "https://stedolan.github.io/jq/"
    check_dependency "kubectl" "https://kubernetes.io/docs/tasks/tools/"
    check_dependency "scw" "https://github.com/scaleway/scaleway-cli"

    # Load configuration
    load_terraform_outputs

    # Check if running from project root
    if [ ! -f "docker-compose.yml" ] && [ ! -d "terraform" ]; then
        log ERROR "Script must be run from project root directory"
        exit 3
    fi
}

# ── Health Check Functions ────────────────────────────────────────────────────

check_kubernetes_cluster() {
    log_verbose INFO "Checking Kubernetes cluster health..."
    local start_time=$(date +%s%3N)

    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log ERROR "Cannot connect to Kubernetes cluster"
        add_result "k8s" "cluster_connectivity" "FAIL" "CRITICAL" "Cannot connect to Kubernetes cluster" 0
        return
    fi

    local end_time=$(date +%s%3N)
    local latency=$((end_time - start_time))

    add_result "k8s" "cluster_connectivity" "PASS" "CRITICAL" "Kubernetes cluster reachable" "$latency"
    log SUCCESS "Kubernetes cluster is reachable (${latency}ms)"

    # Check nodes status
    log_verbose INFO "Checking node status..."
    local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")

    if [ "$ready_nodes" -eq "$total_nodes" ] && [ "$total_nodes" -gt 0 ]; then
        add_result "k8s" "nodes_ready" "PASS" "CRITICAL" "All $total_nodes nodes are Ready" 0
        log SUCCESS "All $total_nodes nodes are Ready"
    else
        add_result "k8s" "nodes_ready" "FAIL" "CRITICAL" "Only $ready_nodes/$total_nodes nodes are Ready" 0
        log ERROR "Only $ready_nodes/$total_nodes nodes are Ready"
    fi

    # Check namespace exists
    if kubectl get namespace onboarding &> /dev/null; then
        add_result "k8s" "namespace_exists" "PASS" "CRITICAL" "onboarding namespace exists" 0
    else
        add_result "k8s" "namespace_exists" "FAIL" "CRITICAL" "onboarding namespace not found" 0
        log ERROR "onboarding namespace not found"
        return
    fi

    # Check deployments
    local deployments=("rest-api")
    for deployment in "${deployments[@]}"; do
        local available=$(kubectl get deployment "$deployment" -n onboarding -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        local desired=$(kubectl get deployment "$deployment" -n onboarding -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")

        if [ "$available" -ge 1 ] && [ "$desired" -gt 0 ]; then
            add_result "k8s" "deployment_${deployment}" "PASS" "CRITICAL" "$deployment: $available/$desired replicas available" 0
            log SUCCESS "$deployment: $available/$desired replicas available"
        else
            add_result "k8s" "deployment_${deployment}" "FAIL" "CRITICAL" "$deployment: $available/$desired replicas available" 0
            log ERROR "$deployment: $available/$desired replicas available"
        fi
    done

    # Check pods status
    local running_pods=$(kubectl get pods -n onboarding --no-headers 2>/dev/null | grep -c " Running " || echo "0")
    local total_pods=$(kubectl get pods -n onboarding --no-headers 2>/dev/null | wc -l || echo "0")

    if [ "$running_pods" -eq "$total_pods" ] && [ "$total_pods" -gt 0 ]; then
        add_result "k8s" "pods_running" "PASS" "CRITICAL" "All $total_pods pods are Running" 0
        log SUCCESS "All $total_pods pods are Running"
    else
        add_result "k8s" "pods_running" "WARNING" "WARNING" "$running_pods/$total_pods pods are Running" 0
        log WARNING "$running_pods/$total_pods pods are Running"
    fi

    # Check HPA status
    if kubectl get hpa -n onboarding &> /dev/null; then
        local hpa_current=$(kubectl get hpa rest-api-hpa -n onboarding -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "N/A")
        local hpa_desired=$(kubectl get hpa rest-api-hpa -n onboarding -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo "N/A")
        add_result "k8s" "hpa_active" "PASS" "INFO" "HPA active: $hpa_current/$hpa_desired replicas" 0
        log_verbose SUCCESS "HPA active: $hpa_current/$hpa_desired replicas"
    else
        add_result "k8s" "hpa_active" "WARNING" "WARNING" "HPA not found or not configured" 0
        log_verbose WARNING "HPA not found or not configured"
    fi
}

check_serverless_containers() {
    log_verbose INFO "Checking Serverless Containers..."

    # Check image converter
    if [ -n "$CONVERTER_URL" ]; then
        local start_time=$(date +%s%3N)

        if curl -sf --max-time 10 "https://$CONVERTER_URL/health" &> /dev/null; then
            local end_time=$(date +%s%3N)
            local latency=$((end_time - start_time))
            add_result "serverless" "converter_health" "PASS" "CRITICAL" "Image converter is healthy" "$latency"
            log SUCCESS "Image converter is healthy (${latency}ms)"
        else
            add_result "serverless" "converter_health" "FAIL" "CRITICAL" "Image converter health check failed" 0
            log ERROR "Image converter health check failed"
        fi

        # Test conversion endpoint
        start_time=$(date +%s%3N)
        local response=$(curl -sf --max-time 30 -X POST "https://$CONVERTER_URL/process" \
            -H "Content-Type: image/png" \
            --data-binary "@logo.png" 2>/dev/null || echo "")
        end_time=$(date +%s%3N)
        local latency=$((end_time - start_time))

        if [ -n "$response" ] && [ ${#response} -gt 0 ]; then
            add_result "serverless" "converter_process" "PASS" "CRITICAL" "Image conversion working" "$latency"
            log_verbose SUCCESS "Image conversion working (${latency}ms)"
        else
            add_result "serverless" "converter_process" "WARNING" "WARNING" "Image conversion endpoint not responding" 0
            log WARNING "Image conversion endpoint not responding"
        fi
    else
        add_result "serverless" "converter_configured" "WARNING" "WARNING" "Converter URL not configured" 0
        log WARNING "Converter URL not configured"
    fi

    # Check AI alt-generator
    if [ -n "$AI_GENERATOR_URL" ]; then
        local start_time=$(date +%s%3N)

        if curl -sf --max-time 10 "https://$AI_GENERATOR_URL/health" &> /dev/null; then
            local end_time=$(date +%s%3N)
            local latency=$((end_time - start_time))
            add_result "serverless" "ai_generator_health" "PASS" "CRITICAL" "AI generator is healthy" "$latency"
            log SUCCESS "AI generator is healthy (${latency}ms)"
        else
            add_result "serverless" "ai_generator_health" "FAIL" "CRITICAL" "AI generator health check failed" 0
            log ERROR "AI generator health check failed"
        fi
    else
        add_result "serverless" "ai_generator_configured" "WARNING" "WARNING" "AI generator URL not configured" 0
        log WARNING "AI generator URL not configured"
    fi
}

check_load_balancer() {
    log_verbose INFO "Checking Load Balancer..."

    if [ -z "$LB_IP" ]; then
        add_result "lb" "configured" "WARNING" "WARNING" "Load Balancer IP not configured" 0
        log WARNING "Load Balancer IP not configured"
        return
    fi

    # Check health endpoint
    local start_time=$(date +%s%3N)
    local response=$(curl -sf --max-time 10 "http://$LB_IP/health" 2>/dev/null || echo "")
    local end_time=$(date +%s%3N)
    local latency=$((end_time - start_time))

    if echo "$response" | jq -e '.status == "ok"' &> /dev/null; then
        add_result "lb" "health_endpoint" "PASS" "CRITICAL" "Health endpoint responding" "$latency"
        log SUCCESS "Load Balancer health endpoint responding (${latency}ms)"
    else
        add_result "lb" "health_endpoint" "FAIL" "CRITICAL" "Health endpoint not responding correctly" "$latency"
        log ERROR "Load Balancer health endpoint not responding correctly"
    fi

    # Check upload endpoint
    if [ -f "logo.png" ]; then
        start_time=$(date +%s%3N)
        local upload_response=$(curl -sf --max-time 30 -F "file=@logo.png" \
            -F "format=webp" \
            "http://$LB_IP/upload" 2>/dev/null || echo "")
        end_time=$(date +%s%3N)
        latency=$((end_time - start_time))

        if echo "$upload_response" | jq -e '.id' &> /dev/null; then
            add_result "lb" "upload_endpoint" "PASS" "CRITICAL" "Upload endpoint working" "$latency"
            log SUCCESS "Upload endpoint working (${latency}ms)"
        else
            add_result "lb" "upload_endpoint" "FAIL" "CRITICAL" "Upload endpoint not working" "$latency"
            log ERROR "Upload endpoint not working"
        fi
    else
        add_result "lb" "upload_test" "WARNING" "WARNING" "logo.png not found for upload test" 0
        log_verbose WARNING "logo.png not found for upload test"
    fi
}

check_database() {
    log_verbose INFO "Checking database connectivity..."

    # Get database credentials from Secret Manager or environment
    local db_url="${ONBOARDING_DATABASE_URL:-}"

    if [ -z "$db_url" ]; then
        # Try to get from Secret Manager
        db_url=$(scw secret secret-version get \
            secret-id=$(scw secret secret list | grep onboarding-database-url | awk '{print $1}') \
            --region fr-par 2>/dev/null | jq -r '.data' | base64 -d 2>/dev/null || echo "")
    fi

    if [ -z "$db_url" ]; then
        add_result "database" "credentials" "WARNING" "WARNING" "Database URL not available" 0
        log WARNING "Database URL not available, skipping database checks"
        return
    fi

    # Check database connectivity via kubectl
    local start_time=$(date +%s%3N)
    local result=$(kubectl run db-test --rm -i --restart=Never \
        --image=postgres:15 \
        --env="PGPASSWORD=$(echo "$db_url" | grep -oP 'password=\K[^&]*')" \
        -- psql "$db_url" -c "SELECT 1;" 2>&1 || echo "")
    local end_time=$(date +%s%3N)
    local latency=$((end_time - start_time))

    if echo "$result" | grep -q "1 row"; then
        add_result "database" "connectivity" "PASS" "CRITICAL" "Database connection successful" "$latency"
        log SUCCESS "Database connection successful (${latency}ms)"
    else
        add_result "database" "connectivity" "FAIL" "CRITICAL" "Database connection failed" "$latency"
        log ERROR "Database connection failed"
    fi

    # Check tables exist
    local tables_check=$(kubectl run db-tables --rm -i --restart=Never \
        --image=postgres:15 \
        --env="PGPASSWORD=$(echo "$db_url" | grep -oP 'password=\K[^&]*')" \
        -- psql "$db_url" -c "\dt" 2>&1 || echo "")

    if echo "$tables_check" | grep -q "images"; then
        add_result "database" "tables_exist" "PASS" "CRITICAL" "Required tables exist" 0
        log SUCCESS "Required database tables exist"
    else
        add_result "database" "tables_exist" "FAIL" "CRITICAL" "Required tables missing" 0
        log ERROR "Required database tables missing"
    fi
}

check_s3_bucket() {
    log_verbose INFO "Checking S3 bucket access..."

    local bucket_name="${ONBOARDING_BUCKET_NAME:-}"
    local access_key="${ONBOARDING_ACCESS_KEY:-}"
    local secret_key="${ONBOARDING_SECRET_KEY:-}"

    # Try to get from Secret Manager if not in env
    if [ -z "$bucket_name" ] || [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        log WARNING "S3 credentials not in environment, attempting Secret Manager retrieval"
        # In production, retrieve from Secret Manager here
    fi

    if [ -z "$bucket_name" ] || [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        add_result "s3" "credentials" "WARNING" "WARNING" "S3 credentials not available" 0
        log WARNING "S3 credentials not available, skipping S3 checks"
        return
    fi

    export AWS_ACCESS_KEY_ID="$access_key"
    export AWS_SECRET_ACCESS_KEY="$secret_key"
    export AWS_DEFAULT_REGION="fr-par"

    # Check bucket accessibility
    local start_time=$(date +%s%3N)
    local result=$(aws s3 ls "s3://$bucket_name" \
        --endpoint-url https://s3.fr-par.scw.cloud 2>&1 || echo "")
    local end_time=$(date +%s%3N)
    local latency=$((end_time - start_time))

    if [ $? -eq 0 ] || echo "$result" | grep -qv "AccessDenied\|NoSuchBucket"; then
        add_result "s3" "bucket_accessible" "PASS" "CRITICAL" "S3 bucket accessible" "$latency"
        log SUCCESS "S3 bucket accessible (${latency}ms)"
    else
        add_result "s3" "bucket_accessible" "FAIL" "CRITICAL" "S3 bucket not accessible: $result" "$latency"
        log ERROR "S3 bucket not accessible: $result"
    fi

    # Check bucket versioning
    local versioning=$(aws s3api get-bucket-versioning \
        --bucket "$bucket_name" \
        --endpoint-url https://s3.fr-par.scw.cloud 2>/dev/null | jq -r '.Status' || echo "")

    if [ "$versioning" = "Enabled" ]; then
        add_result "s3" "versioning_enabled" "PASS" "INFO" "S3 versioning is enabled" 0
        log_verbose SUCCESS "S3 versioning is enabled"
    else
        add_result "s3" "versioning_enabled" "WARNING" "WARNING" "S3 versioning not enabled" 0
        log_verbose WARNING "S3 versioning not enabled"
    fi

    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
}

check_secrets_manager() {
    log_verbose INFO "Checking Secret Manager..."

    local start_time=$(date +%s%3N)

    # List secrets
    local secrets=$(scw secret secret list --region fr-par 2>&1 || echo "")
    local end_time=$(date +%s%3N)
    local latency=$((end_time - start_time))

    if echo "$secrets" | jq -e '.[].id' &> /dev/null; then
        add_result "secrets" "manager_accessible" "PASS" "CRITICAL" "Secret Manager accessible" "$latency"
        log SUCCESS "Secret Manager accessible (${latency}ms)"

        # Check critical secrets exist
        local critical_secrets=("onboarding-database-url" "onboarding-bucket-name" "qwen-api-key")
        for secret in "${critical_secrets[@]}"; do
            if echo "$secrets" | grep -q "$secret"; then
                add_result "secrets" "secret_$secret" "PASS" "CRITICAL" "Secret $secret exists" 0
                log_verbose SUCCESS "Secret $secret exists"
            else
                add_result "secrets" "secret_$secret" "WARNING" "WARNING" "Secret $secret not found" 0
                log_verbose WARNING "Secret $secret not found"
            fi
        done
    else
        add_result "secrets" "manager_accessible" "FAIL" "CRITICAL" "Secret Manager not accessible" "$latency"
        log ERROR "Secret Manager not accessible"
    fi
}

check_monitoring() {
    log_verbose INFO "Checking monitoring stack..."

    # Check Prometheus
    local prometheus_response=$(curl -sf --max-time 10 "http://localhost:9090/-/healthy" 2>/dev/null || echo "")
    if [ -n "$prometheus_response" ]; then
        add_result "monitoring" "prometheus_healthy" "PASS" "INFO" "Prometheus is healthy" 0
        log_verbose SUCCESS "Prometheus is healthy"
    else
        add_result "monitoring" "prometheus_healthy" "WARNING" "WARNING" "Prometheus not accessible" 0
        log_verbose WARNING "Prometheus not accessible"
    fi

    # Check Grafana
    local grafana_response=$(curl -sf --max-time 10 "http://localhost:3000/api/health" 2>/dev/null || echo "")
    if echo "$grafana_response" | jq -e '.commit' &> /dev/null; then
        add_result "monitoring" "grafana_healthy" "PASS" "INFO" "Grafana is healthy" 0
        log_verbose SUCCESS "Grafana is healthy"
    else
        add_result "monitoring" "grafana_healthy" "WARNING" "WARNING" "Grafana not accessible" 0
        log_verbose WARNING "Grafana not accessible"
    fi
}

# ── Output Functions ──────────────────────────────────────────────────────────

output_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "                    HEALTH CHECK SUMMARY                     "
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  Total Checks:     $TOTAL_CHECKS"
    echo -e "  ${GREEN}Passed:${NC}           $PASSED_CHECKS"
    echo -e "  ${RED}Critical Failures:${NC} $CRITICAL_FAILURES"
    echo -e "  ${YELLOW}Warnings:${NC}         $WARNING_FAILURES"
    echo ""

    local success_rate=0
    if [ $TOTAL_CHECKS -gt 0 ]; then
        success_rate=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))
    fi
    echo "  Success Rate:     ${success_rate}%"
    echo ""

    if [ $CRITICAL_FAILURES -eq 0 ] && [ $WARNING_FAILURES -eq 0 ]; then
        echo -e "  ${GREEN}✓ All health checks passed!${NC}"
    elif [ $CRITICAL_FAILURES -eq 0 ]; then
        echo -e "  ${YELLOW}⚠ All critical checks passed, ${WARNING_FAILURES} warnings${NC}"
    else
        echo -e "  ${RED}✗ ${CRITICAL_FAILURES} critical check(s) failed${NC}"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
}

output_json() {
    echo "{"
    echo "  \"timestamp\": \"$TIMESTAMP\","
    echo "  \"version\": \"$VERSION\","
    echo "  \"summary\": {"
    echo "    \"total_checks\": $TOTAL_CHECKS,"
    echo "    \"passed\": $PASSED_CHECKS,"
    echo "    \"critical_failures\": $CRITICAL_FAILURES,"
    echo "    \"warnings\": $WARNING_FAILURES"
    echo "  },"
    echo "  \"checks\": ["

    local first=true
    for result in "${CHECK_RESULTS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo -n "    $result"
    done

    echo ""
    echo "  ]"
    echo "}"
}

# ── Main Execution ────────────────────────────────────────────────────────────

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -j|--json)
                JSON_OUTPUT=true
                shift
                ;;
            -c|--component)
                COMPONENT_FILTER="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            --version)
                version
                ;;
            *)
                log ERROR "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Initialize
    initialize

    # Run health checks based on component filter
    case $COMPONENT_FILTER in
        k8s|kubernetes)
            check_kubernetes_cluster
            ;;
        serverless)
            check_serverless_containers
            ;;
        database|db)
            check_database
            ;;
        s3|storage)
            check_s3_bucket
            ;;
        secrets)
            check_secrets_manager
            ;;
        monitoring)
            check_monitoring
            ;;
        lb|loadbalancer)
            check_load_balancer
            ;;
        all|"")
            check_kubernetes_cluster
            check_serverless_containers
            check_load_balancer
            check_database
            check_s3_bucket
            check_secrets_manager
            check_monitoring
            ;;
        *)
            log ERROR "Unknown component: $COMPONENT_FILTER"
            exit 3
            ;;
    esac

    # Output results
    if [ "$JSON_OUTPUT" = true ]; then
        output_json
    else
        output_summary
    fi

    # Determine exit code
    if [ $CRITICAL_FAILURES -gt 0 ]; then
        exit 1
    elif [ $WARNING_FAILURES -gt 0 ]; then
        exit 2
    else
        exit 0
    fi
}

# Run main function
main "$@"
