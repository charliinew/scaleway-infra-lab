#!/usr/bin/env bash
#
# test-wcag.sh - WCAG Compliance Testing for AI-Generated Alt-Text
#
# Usage: ./test-wcag.sh [OPTIONS]
#
# Options:
#   -i, --image FILE           Test image file (default: logo.png)
#   -u, --url URL              API URL (default: auto-detect from Terraform)
#   -l, --max-length NUMBER    Max alt-text length (default: 125, WCAG recommended)
#   -o, --output FILE          Output report file (default: wcag-test-report.json)
#   -v, --verbose              Enable verbose output
#   -h, --help                 Show this help message
#
# WCAG 2.1 Success Criteria:
# - 1.1.1 Non-text Content (Level A)
# - 1.4.5 Images of Text (Level AA)
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

IMAGE_FILE="logo.png"
API_URL=""
MAX_LENGTH=125
OUTPUT_FILE="wcag-test-report.json"
VERBOSE=false

# WCAG thresholds
MIN_LENGTH=5
MAX_CONFIDENCE=0.5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Helper Functions ───────────────────────────────────────────────────────────

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

show_help() {
    cat << EOF
WCAG Compliance Testing for AI-Generated Alt-Text

Usage: $0 [OPTIONS]

Options:
  -i, --image FILE           Test image file (default: logo.png)
  -u, --url URL              API URL (default: auto-detect)
  -l, --max-length NUMBER    Max alt-text length (default: 125)
  -o, --output FILE          Output report file (default: wcag-test-report.json)
  -v, --verbose              Enable verbose output
  -h, --help                 Show this help message

WCAG 2.1 Criteria Tested:
  - 1.1.1 Non-text Content (Level A)
  - 1.4.5 Images of Text (Level AA)

Examples:
  $0 -i test-image.png
  $0 --image logo.png --max-length 100
  $0 -v -o report.json

EOF
    exit 0
}

# ── Parse Arguments ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--image)
            IMAGE_FILE="$2"
            shift 2
            ;;
        -u|--url)
            API_URL="$2"
            shift 2
            ;;
        -l|--max-length)
            MAX_LENGTH="$2"
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
            exit 1
            ;;
    esac
done

# ── Auto-detect API URL ────────────────────────────────────────────────────────

if [ -z "$API_URL" ]; then
    log_info "Auto-detecting API URL..."

    if command -v terraform &> /dev/null && [ -d "terraform" ]; then
        LB_IP=$(cd terraform && terraform output -raw load_balancer_ip 2>/dev/null || echo "")
        if [ -n "$LB_IP" ]; then
            API_URL="http://$LB_IP"
            log_info "Detected: $API_URL"
        fi
    fi

    if [ -z "$API_URL" ]; then
        API_URL="http://localhost:8080"
        log_warning "Using default: $API_URL"
    fi
fi

# ── Validation Functions ───────────────────────────────────────────────────────

validate_alt_text_length() {
    local alt_text="$1"
    local length=${#alt_text}

    if [ $length -le $MAX_LENGTH ]; then
        log_verbose "Alt-text length: $length chars (≤ $MAX_LENGTH ✓)"
        return 0
    else
        log_verbose "Alt-text length: $length chars (> $MAX_LENGTH ✗)"
        return 1
    fi
}

validate_alt_text_not_empty() {
    local alt_text="$1"

    if [ -n "$alt_text" ] && [ "$alt_text" != "" ]; then
        log_verbose "Alt-text is not empty ✓"
        return 0
    else
        log_verbose "Alt-text is empty ✗"
        return 1
    fi
}

validate_no_image_of() {
    local alt_text="$1"

    if echo "$alt_text" | grep -qi "image of\|picture of\|photo of"; then
        log_verbose "Contains redundant phrase (image of, picture of) ✗"
        return 1
    else
        log_verbose "No redundant phrases ✓"
        return 0
    fi
}

validate_descriptive() {
    local alt_text="$1"
    local word_count=$(echo "$alt_text" | wc -w)

    if [ $word_count -ge 3 ]; then
        log_verbose "Alt-text has $word_count words (≥ 3 ✓)"
        return 0
    else
        log_verbose "Alt-text has only $word_count words (< 3 ✗)"
        return 1
    fi
}

validate_confidence() {
    local confidence="$1"

    # Convert to integer for comparison (multiply by 100)
    local conf_int=$(echo "$confidence * 100" | bc | cut -d'.' -f1)
    local threshold_int=$(echo "$MAX_CONFIDENCE * 100" | bc | cut -d'.' -f1)

    if [ "$conf_int" -ge "$threshold_int" ]; then
        log_verbose "Confidence: $confidence (≥ $MAX_CONFIDENCE ✓)"
        return 0
    else
        log_verbose "Confidence: $confidence (< $MAX_CONFIDENCE ✗)"
        return 1
    fi
}

validate_html_tag() {
    local html_tag="$1"

    # Check for required attributes
    local checks_passed=0
    local total_checks=3

    if echo "$html_tag" | grep -q 'alt='; then
        checks_passed=$((checks_passed + 1))
        log_verbose "HTML has alt attribute ✓"
    fi

    if echo "$html_tag" | grep -q '<img'; then
        checks_passed=$((checks_passed + 1))
        log_verbose "HTML has img tag ✓"
    fi

    if echo "$html_tag" | grep -q 'loading='; then
        checks_passed=$((checks_passed + 1))
        log_verbose "HTML has loading attribute ✓"
    fi

    if [ $checks_passed -ge $total_checks ]; then
        return 0
    else
        log_verbose "HTML tag incomplete ($checks_passed/$total_checks)"
        return 1
    fi
}

# ── Test Functions ────────────────────────────────────────────────────────────

run_single_test() {
    local image_file="$1"
    local test_num="$2"

    log_info "Test $test_num: Testing $image_file"

    if [ ! -f "$image_file" ]; then
        log_error "Image file not found: $image_file"
        return 1
    fi

    # Call AI Alt Generator
    local response
    response=$(curl -s -X POST \
        -F "file=@$image_file" \
        "${API_URL}/generate-alt" 2>/dev/null)

    if [ -z "$response" ]; then
        log_error "Empty response from API"
        return 1
    fi

    # Parse response
    local alt_text=$(echo "$response" | jq -r '.alt_text // ""')
    local description=$(echo "$response" | jq -r '.description // ""')
    local html_tag=$(echo "$response" | jq -r '.html // ""')
    local image_type=$(echo "$response" | jq -r '.image_type // "unknown"')
    local confidence=$(echo "$response" | jq -r '.confidence // "0"')
    local decorative=$(echo "$response" | jq -r '.decorative // false')

    log_verbose "Response:"
    log_verbose "  Alt-text: $alt_text"
    log_verbose "  Type: $image_type"
    log_verbose "  Confidence: $confidence"
    log_verbose "  Decorative: $decorative"

    # Run WCAG validations
    local tests_passed=0
    local tests_total=0
    local failures=""

    # Test 1: Length check (WCAG 1.1.1)
    tests_total=$((tests_total + 1))
    if validate_alt_text_length "$alt_text"; then
        tests_passed=$((tests_passed + 1))
        log_success "WCAG 1.1.1: Alt-text length ≤ $MAX_LENGTH chars"
    else
        failures="${failures}WCAG 1.1.1: Alt-text too long (${#alt_text} chars)\n"
        log_warning "WCAG 1.1.1: Alt-text length > $MAX_LENGTH chars"
    fi

    # Test 2: Not empty (unless decorative)
    if [ "$decorative" = "false" ]; then
        tests_total=$((tests_total + 1))
        if validate_alt_text_not_empty "$alt_text"; then
            tests_passed=$((tests_passed + 1))
            log_success "WCAG 1.1.1: Alt-text is not empty"
        else
            failures="${failures}WCAG 1.1.1: Alt-text is empty for non-decorative image\n"
            log_warning "WCAG 1.1.1: Alt-text is empty"
        fi
    else
        log_info "Image marked as decorative (empty alt acceptable)"
    fi

    # Test 3: No redundant phrases
    tests_total=$((tests_total + 1))
    if validate_no_image_of "$alt_text"; then
        tests_passed=$((tests_passed + 1))
        log_success "WCAG BP: No redundant phrases (image of, picture of)"
    else
        failures="${failures}Best Practice: Contains redundant phrases\n"
        log_warning "Best Practice: Remove 'image of', 'picture of'"
    fi

    # Test 4: Descriptive enough
    tests_total=$((tests_total + 1))
    if validate_descriptive "$alt_text"; then
        tests_passed=$((tests_passed + 1))
        log_success "WCAG BP: Alt-text is descriptive (≥ 3 words)"
    else
        failures="${failures}Best Practice: Alt-text too short\n"
        log_warning "Best Practice: Alt-text should be more descriptive"
    fi

    # Test 5: Confidence threshold
    tests_total=$((tests_total + 1))
    if validate_confidence "$confidence"; then
        tests_passed=$((tests_passed + 1))
        log_success "AI Quality: Confidence ≥ $MAX_CONFIDENCE"
    else
        failures="${failures}AI Quality: Low confidence ($confidence)\n"
        log_warning "AI Quality: Low confidence score"
    fi

    # Test 6: HTML tag validity
    tests_total=$((tests_total + 1))
    if [ -n "$html_tag" ] && validate_html_tag "$html_tag"; then
        tests_passed=$((tests_passed + 1))
        log_success "HTML: Valid img tag with accessibility attributes"
    else
        failures="${failures}HTML: Invalid or incomplete img tag\n"
        log_warning "HTML: Img tag missing required attributes"
    fi

    # Calculate score
    local score=0
    if [ $tests_total -gt 0 ]; then
        score=$((tests_passed * 100 / tests_total))
    fi

    # Display results
    echo ""
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│ Test Results                                            │"
    echo "├─────────────────────────────────────────────────────────┤"
    printf "│ Image: %-51s │\n" "$(basename "$image_file")"
    printf "│ Type: %-52s │\n" "$image_type"
    printf "│ Alt-text: %-48s │\n" "${alt_text:0:48}"
    printf "│ Confidence: %-46s │\n" "$confidence"
    echo "├─────────────────────────────────────────────────────────┤"
    printf "│ Tests Passed: $tests_passed/$tests_total                                       │\n"
    printf "│ Score: ${score}%                                               │\n"
    echo "└─────────────────────────────────────────────────────────┘"

    if [ $tests_passed -eq $tests_total ]; then
        log_success "All WCAG tests passed! ✓"
        return 0
    else
        log_warning "Some tests failed. Score: ${score}%"
        if [ "$VERBOSE" = true ]; then
            echo -e "$failures"
        fi
        return 1
    fi
}

# ── Generate Report ────────────────────────────────────────────────────────────

generate_report() {
    local results="$1"
    local total_tests="$2"
    local passed_tests="$3"

    local score=0
    if [ $total_tests -gt 0 ]; then
        score=$((passed_tests * 100 / total_tests))
    fi

    cat > "$OUTPUT_FILE" << EOF
{
  "report_info": {
    "generated_at": "$(date -Iseconds)",
    "api_url": "$API_URL",
    "max_alt_text_length": $MAX_LENGTH,
    "wcag_version": "2.1",
    "criteria_tested": [
      "1.1.1 Non-text Content (Level A)",
      "1.4.5 Images of Text (Level AA)"
    ]
  },
  "summary": {
    "total_tests": $total_tests,
    "passed": $passed_tests,
    "failed": $((total_tests - passed_tests)),
    "score_percent": $score,
    "compliance_level": "$([ $score -ge 90 ] && echo "AA" || ([ $score -ge 70 ] && echo "A" || echo "Non-compliant"))"
  },
  "thresholds": {
    "max_alt_text_length": $MAX_LENGTH,
    "min_alt_text_length": $MIN_LENGTH,
    "min_confidence": $MAX_CONFIDENCE
  },
  "results": $results
}
EOF

    log_info "Report saved to: $OUTPUT_FILE"
}

# ── Main Test Suite ────────────────────────────────────────────────────────────

run_test_suite() {
    log_info "Running WCAG Compliance Test Suite"
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     WCAG 2.1 Alt-Text Compliance Testing                 ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    log_info "API URL: $API_URL"
    log_info "Max alt-text length: $MAX_LENGTH characters"
    log_info "Test image: $IMAGE_FILE"
    echo ""

    # Check API accessibility
    log_info "Checking API accessibility..."
    if ! curl -s --max-time 5 "${API_URL}/health" | jq -e '.status' &> /dev/null; then
        log_error "API not accessible at $API_URL"
        exit 1
    fi
    log_success "API is accessible"

    # Check if test image exists
    if [ ! -f "$IMAGE_FILE" ]; then
        log_error "Test image not found: $IMAGE_FILE"
        log_info "Create a test image or use: -i <path>"
        exit 1
    fi

    # Run tests
    local total_tests=1
    local passed_tests=0

    echo ""
    echo "Running WCAG validation tests..."
    echo ""

    if run_single_test "$IMAGE_FILE" 1; then
        passed_tests=$((passed_tests + 1))
    fi

    # Generate report
    echo ""
    log_info "Generating compliance report..."

    local results="[{\"image\": \"$IMAGE_FILE\", \"passed\": $([ $passed_tests -eq $total_tests ] && echo "true" || echo "false") }]"
    generate_report "$results" "$total_tests" "$passed_tests"

    # Final summary
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    if [ $passed_tests -eq $total_tests ]; then
        echo "║  ✅ WCAG Compliance: PASSED (${passed_tests}/${total_tests})                    ║"
    else
        echo "║  ⚠️  WCAG Compliance: PARTIAL (${passed_tests}/${total_tests})                  ║"
    fi
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    return $([ $passed_tests -eq $total_tests ] && echo "0" || echo "1")
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
    run_test_suite
}

main "$@"
