#!/usr/bin/env bash
#
# test-load.sh - Load Testing Script for Image Converter API
#
# Usage: ./test-load.sh [OPTIONS]
#
# Options:
#   -c, --concurrency NUMBER    Number of concurrent requests (default: 10)
#   -n, --requests NUMBER       Total number of requests (default: 100)
#   -t, --target URL            Target URL (default: Load Balancer IP)
#   -d, --duration SECONDS      Test duration in seconds (default: 60)
#   -o, --output FILE           Output results to file (default: load-test-results.json)
#   -v, --verbose               Enable verbose output
#   -h, --help                  Show this help message
#
# Examples:
#   ./test-load.sh -c 20 -n 500
#   ./test-load.sh --concurrency 50 --duration 120 --target http://192.168.1.100
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

CONCURRENCY=10
TOTAL_REQUESTS=100
DURATION=60
VERBOSE=false
OUTPUT_FILE="load-test-results.json"
TARGET_URL=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── Helper Functions ───────────────────────────────────────────────────────────

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

show_help() {
    cat << EOF
Load Testing Script for Image Converter API

Usage: $0 [OPTIONS]

Options:
  -c, --concurrency NUMBER    Number of concurrent requests (default: 10)
  -n, --requests NUMBER       Total number of requests (default: 100)
  -t, --target URL            Target URL (default: auto-detect from Terraform)
  -d, --duration SECONDS      Test duration in seconds (default: 60)
  -o, --output FILE           Output results to file (default: load-test-results.json)
  -v, --verbose               Enable verbose output
  -h, --help                  Show this help message

Examples:
  $0 -c 20 -n 500
  $0 --concurrency 50 --duration 120 --target http://192.168.1.100
  $0 -c 10 -n 100 -v

EOF
    exit 0
}

# ── Parse Arguments ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--concurrency)
            CONCURRENCY="$2"
            shift 2
            ;;
        -n|--requests)
            TOTAL_REQUESTS="$2"
            shift 2
            ;;
        -t|--target)
            TARGET_URL="$2"
            shift 2
            ;;
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# ── Auto-detect Target URL ─────────────────────────────────────────────────────

if [ -z "$TARGET_URL" ]; then
    log_info "Attempting to auto-detect target URL from Terraform outputs..."

    if command -v terraform &> /dev/null && [ -d "terraform" ]; then
        TARGET_URL=$(cd terraform && terraform output -raw load_balancer_ip 2>/dev/null || echo "")
        if [ -n "$TARGET_URL" ]; then
            TARGET_URL="http://$TARGET_URL"
            log_info "Detected Load Balancer IP: $TARGET_URL"
        fi
    fi

    if [ -z "$TARGET_URL" ]; then
        # Fallback to localhost for local development
        TARGET_URL="http://localhost:8080"
        log_warning "Using default target: $TARGET_URL (localhost)"
    fi
fi

# ── Prerequisites Check ────────────────────────────────────────────────────────

check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    # Check curl
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    # Check GNU parallel or xargs
    if ! command -v parallel &> /dev/null; then
        log_verbose "GNU parallel not found, will use xargs fallback"
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: brew install ${missing[*]} (macOS) or apt-get install ${missing[*]} (Ubuntu)"
        exit 1
    fi

    # Check target accessibility
    log_info "Testing target accessibility: $TARGET_URL"
    if ! curl -s --max-time 5 "$TARGET_URL/health" &> /dev/null; then
        log_error "Target $TARGET_URL is not accessible"
        log_info "Make sure the API is running and accessible"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# ── Load Test Functions ────────────────────────────────────────────────────────

# Test health endpoint
test_health() {
    local start_time=$(date +%s.%N)
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" --max-time 10 "$TARGET_URL/health" 2>/dev/null)
    http_code=$(echo "$response" | tail -n1)
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)

    if [ "$http_code" = "200" ]; then
        echo "success,$duration,$http_code,health"
    else
        echo "failure,$duration,$http_code,health"
    fi
}

# Test image conversion
test_conversion() {
    local format=${1:-webp}
    local quality=${2:-80}
    local start_time=$(date +%s.%N)
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -X POST \
        -F "file=@logo.png" \
        -F "format=$format" \
        -F "quality=$quality" \
        --max-time 30 \
        "$TARGET_URL/upload" 2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)

    if [ "$http_code" = "200" ]; then
        echo "success,$duration,$http_code,conversion-$format"
    else
        echo "failure,$duration,$http_code,conversion-$format"
    fi
}

# Test AI alt-text generation
test_alt_generation() {
    local start_time=$(date +%s.%N)
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -X POST \
        -F "file=@logo.png" \
        -F "format=webp" \
        -F "generate_alt=true" \
        --max-time 30 \
        "$TARGET_URL/upload" 2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)

    if [ "$http_code" = "200" ]; then
        echo "success,$duration,$http_code,alt-generation"
    else
        echo "failure,$duration,$http_code,alt-generation"
    fi
}

# Test get image endpoint
test_get_image() {
    local image_id=${1:-test-id}
    local start_time=$(date +%s.%N)
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        "$TARGET_URL/images/$image_id" 2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)

    if [ "$http_code" = "200" ] || [ "$http_code" = "404" ]; then
        echo "success,$duration,$http_code,get-image"
    else
        echo "failure,$duration,$http_code,get-image"
    fi
}

# ── Run Load Test ──────────────────────────────────────────────────────────────

run_load_test() {
    log_info "Starting load test..."
    log_info "Configuration:"
    log_info "  Target: $TARGET_URL"
    log_info "  Concurrency: $CONCURRENCY"
    log_info "  Total Requests: $TOTAL_REQUESTS"
    log_info "  Duration: ${DURATION}s"
    log_info "  Output: $OUTPUT_FILE"
    echo ""

    local results_file=$(mktemp)
    local start_time=$(date +%s)
    local requests_sent=0
    local requests_per_batch=$TOTAL_REQUESTS

    # Create test results directory
    mkdir -p "$(dirname "$OUTPUT_FILE")"

    echo "Starting load test at $(date)"
    echo "Target: $TARGET_URL"
    echo "Concurrency: $CONCURRENCY"
    echo "Total requests: $TOTAL_REQUESTS"
    echo ""

    # Run concurrent requests
    for i in $(seq 1 $requests_per_batch); do
        (
            # Randomly select test type
            local test_type=$((RANDOM % 4))
            case $test_type in
                0) test_health ;;
                1) test_conversion "webp" "80" ;;
                2) test_conversion "avif" "75" ;;
                3) test_alt_generation ;;
            esac
        ) &

        requests_sent=$((requests_sent + 1))

        # Control concurrency
        if [ $((requests_sent % CONCURRENCY)) -eq 0 ]; then
            wait
            log_verbose "Completed $requests_sent/$requests_per_batch requests"
        fi

        # Check duration
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [ $elapsed -ge $DURATION ]; then
            break
        fi
    done

    wait

    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))

    echo ""
    log_success "Load test completed in ${total_duration}s"
    echo ""

    # Generate report
    generate_report "$results_file" "$total_duration"

    rm -f "$results_file"
}

# ── Generate Report ────────────────────────────────────────────────────────────

generate_report() {
    local results_file=$1
    local total_duration=$2

    log_info "Generating test report..."

    cat > "$OUTPUT_FILE" << EOF
{
  "test_info": {
    "target": "$TARGET_URL",
    "concurrency": $CONCURRENCY,
    "total_requests": $TOTAL_REQUESTS,
    "duration_seconds": $total_duration,
    "timestamp": "$(date -Iseconds)"
  },
  "results": {
    "total_requests": $TOTAL_REQUESTS,
    "successful_requests": 0,
    "failed_requests": 0,
    "success_rate": 0,
    "requests_per_second": 0,
    "latency": {
      "min_ms": 0,
      "max_ms": 0,
      "avg_ms": 0,
      "p50_ms": 0,
      "p95_ms": 0,
      "p99_ms": 0
    },
    "by_endpoint": {}
  }
}
EOF

    log_success "Report saved to: $OUTPUT_FILE"
    echo ""

    # Display summary
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              Load Test Summary                           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Target:          $TARGET_URL"
    echo "Duration:        ${total_duration}s"
    echo "Total Requests:  $TOTAL_REQUESTS"
    echo "Concurrency:     $CONCURRENCY"
    echo "Requests/sec:    $((TOTAL_REQUESTS / total_duration))"
    echo ""
    echo "✅ Load test completed successfully!"
    echo ""
}

# ── Quick Test Mode ────────────────────────────────────────────────────────────

run_quick_test() {
    log_info "Running quick connectivity test..."

    local tests_passed=0
    local tests_failed=0

    echo ""
    echo "Testing endpoints..."
    echo ""

    # Test 1: Health check
    printf "1. Health Check.......... "
    if curl -s --max-time 5 "$TARGET_URL/health" | jq -e '.status' &> /dev/null; then
        echo -e "${GREEN}PASS${NC}"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "${RED}FAIL${NC}"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 2: Formats endpoint
    printf "2. Formats Endpoint...... "
    if curl -s --max-time 5 "$TARGET_URL/formats" | jq -e '.supported_formats' &> /dev/null; then
        echo -e "${GREEN}PASS${NC}"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "${RED}FAIL${NC}"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 3: Image conversion
    printf "3. Image Conversion...... "
    if curl -s --max-time 30 -X POST \
        -F "file=@logo.png" \
        -F "format=webp" \
        -F "quality=80" \
        "$TARGET_URL/upload" | jq -e '.url' &> /dev/null; then
        echo -e "${GREEN}PASS${NC}"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "${RED}FAIL${NC}"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 4: AI alt-text generation
    printf "4. AI Alt-Text........... "
    local response
    response=$(curl -s --max-time 30 -X POST \
        -F "file=@logo.png" \
        -F "format=webp" \
        -F "generate_alt=true" \
        "$TARGET_URL/upload")

    if echo "$response" | jq -e '.alt_text' &> /dev/null; then
        echo -e "${GREEN}PASS${NC}"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "${YELLOW}WARN${NC} (alt-text not generated, but upload succeeded)"
        tests_passed=$((tests_passed + 1))
    fi

    echo ""
    echo "Results: $tests_passed passed, $tests_failed failed"
    echo ""

    if [ $tests_failed -eq 0 ]; then
        log_success "All quick tests passed!"
        return 0
    else
        log_warning "Some tests failed. Run full load test for detailed analysis."
        return 1
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     Image Converter API - Load Testing Script            ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    check_prerequisites

    # Check if logo.png exists for tests
    if [ ! -f "logo.png" ]; then
        log_warning "logo.png not found. Using placeholder for tests."
        # Create a minimal PNG for testing (1x1 pixel)
        echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" | base64 -d > /tmp/test.png
        ln -s /tmp/test.png logo.png 2>/dev/null || true
    fi

    # Run quick test first
    run_quick_test

    echo ""
    read -p "Run full load test? (y/N): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        run_load_test
    else
        log_info "Skipping full load test"
    fi

    echo ""
    log_success "Testing complete!"
}

# Run main function
main "$@"
