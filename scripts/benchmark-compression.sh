#!/usr/bin/env bash
#
# benchmark-compression.sh - Image Compression Benchmark Script
#
# Usage: ./benchmark-compression.sh [OPTIONS]
#
# Options:
#   -i, --image FILE          Test image file (default: logo.png)
#   -u, --url URL             Converter service URL (default: auto-detect)
#   -q, --qualities LIST      Quality levels to test, comma-separated (default: 60,70,80,90,100)
#   -f, --formats LIST        Formats to test, comma-separated (default: webp,avif,jpeg)
#   -o, --output FILE         Output report file (default: compression-benchmark.json)
#   -v, --verbose             Enable verbose output
#   -h, --help                Show this help message
#
# This script benchmarks image compression across different formats and quality levels
# to help determine optimal settings for your use case.
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

IMAGE_FILE="logo.png"
CONVERTER_URL=""
QUALITIES="60,70,80,90,100"
FORMATS="webp,avif,jpeg"
OUTPUT_FILE="compression-benchmark.json"
VERBOSE=false
OUTPUT_DIR="benchmark-results"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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

log_format() {
    echo -e "${MAGENTA}[FORMAT]${NC} $1"
}

show_help() {
    cat << EOF
Image Compression Benchmark Script

Usage: $0 [OPTIONS]

Options:
  -i, --image FILE          Test image file (default: logo.png)
  -u, --url URL             Converter service URL (default: auto-detect)
  -q, --qualities LIST      Quality levels to test (default: 60,70,80,90,100)
  -f, --formats LIST        Formats to test (default: webp,avif,jpeg)
  -o, --output FILE         Output report file (default: compression-benchmark.json)
  -v, --verbose             Enable verbose output
  -h, --help                Show this help message

Examples:
  $0 -i test-image.png
  $0 --qualities 50,75,90 --formats webp,avif
  $0 -v -o results.json

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
            CONVERTER_URL="$2"
            shift 2
            ;;
        -q|--qualities)
            QUALITIES="$2"
            shift 2
            ;;
        -f|--formats)
            FORMATS="$2"
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

# ── Auto-detect Converter URL ─────────────────────────────────────────────────

if [ -z "$CONVERTER_URL" ]; then
    log_info "Auto-detecting converter URL..."

    if command -v terraform &> /dev/null && [ -d "terraform" ]; then
        CONVERTER_URL=$(cd terraform && terraform output -raw image_converter_url 2>/dev/null || echo "")
        if [ -n "$CONVERTER_URL" ]; then
            log_info "Detected: $CONVERTER_URL"
        fi
    fi

    if [ -z "$CONVERTER_URL" ]; then
        CONVERTER_URL="http://localhost:9090"
        log_warning "Using default: $CONVERTER_URL"
    fi
fi

# ── Benchmark Functions ────────────────────────────────────────────────────────

# Convert image and measure results
convert_and_measure() {
    local format="$1"
    local quality="$2"
    local input_file="$3"
    local output_file="${OUTPUT_DIR}/test_${quality}_${format}"

    local start_time=$(date +%s.%N)

    # Call converter API
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -F "file=@$input_file" \
        -F "format=$format" \
        -F "quality=$quality" \
        --max-time 30 \
        "$CONVERTER_URL/convert" 2>/dev/null)

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)

    if [ "$http_code" != "200" ]; then
        log_verbose "Conversion failed: HTTP $http_code"
        echo "failed,$duration,0,0,0,$http_code"
        return 1
    fi

    # Extract size from response headers if available
    local converted_size=$(echo "$body" | jq -r '.converted_size // 0' 2>/dev/null)
    local original_size=$(echo "$body" | jq -r '.original_size // 0' 2>/dev/null)
    local compression_ratio=$(echo "$body" | jq -r '.compression_ratio // "0%"' 2>/dev/null)

    # If API doesn't return sizes, calculate from response
    if [ "$converted_size" = "0" ] || [ "$converted_size" = "null" ]; then
        converted_size=$(echo "$body" | wc -c)
    fi

    if [ "$original_size" = "0" ] || [ "$original_size" = "null" ]; then
        original_size=$(stat -f%z "$input_file" 2>/dev/null || stat -c%s "$input_file" 2>/dev/null || echo "0")
    fi

    echo "success,$duration,$original_size,$converted_size,$compression_ratio,$http_code"
}

# Calculate compression statistics
calculate_stats() {
    local format="$1"
    local results_file="$2"

    log_format "Analyzing $format results..."

    # Read results and calculate averages
    local total_duration=0
    local total_original=0
    local total_converted=0
    local count=0
    local best_ratio=100
    local worst_ratio=0

    while IFS=, read -r status duration original converted ratio http_code; do
        if [ "$status" = "success" ]; then
            total_duration=$(echo "$total_duration + $duration" | bc)
            total_original=$((total_original + original))
            total_converted=$((total_converted + converted))
            count=$((count + 1))

            # Extract numeric ratio for comparison
            local ratio_num=$(echo "$ratio" | sed 's/%//g')
            if (( $(echo "$ratio_num < $best_ratio" | bc -l) )); then
                best_ratio=$ratio_num
            fi
            if (( $(echo "$ratio_num > $worst_ratio" | bc -l) )); then
                worst_ratio=$ratio_num
            fi
        fi
    done < "$results_file"

    if [ $count -gt 0 ]; then
        local avg_duration=$(echo "scale=3; $total_duration / $count" | bc)
        local avg_size=$((total_converted / count))
        local avg_ratio=$(echo "scale=1; $total_converted * 100 / $total_original" | bc)

        echo "$count,$avg_duration,$avg_size,$avg_ratio,$best_ratio,$worst_ratio"
    else
        echo "0,0,0,0,0,0"
    fi
}

# Generate comparison table
generate_table() {
    local results="$1"

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│           Image Compression Benchmark Results                       │"
    echo "├──────────┬──────────┬──────────┬──────────┬──────────┬─────────────┤"
    echo "│ Format   │ Quality  │ Original │ Converted│ Ratio    │ Time (ms)   │"
    echo "├──────────┼──────────┼──────────┼──────────┼──────────┼─────────────┤"

    echo "$results" | while IFS=, read -r format quality original converted ratio time; do
        if [ "$format" != "format" ]; then
            printf "│ %-8s │ %-8s │ %-8s │ %-8s │ %-8s │ %-11s │\n" \
                "$format" "$quality" "$original" "$converted" "$ratio" "$time"
        fi
    done

    echo "└──────────┴──────────┴──────────┴──────────┴──────────┴─────────────┘"
}

# Generate JSON report
generate_report() {
    local all_results="$1"
    local original_size="$2"

    mkdir -p "$(dirname "$OUTPUT_FILE")"
    mkdir -p "$OUTPUT_DIR"

    cat > "$OUTPUT_FILE" << EOF
{
  "benchmark_info": {
    "generated_at": "$(date -Iseconds)",
    "converter_url": "$CONVERTER_URL",
    "test_image": "$IMAGE_FILE",
    "original_size_bytes": $original_size,
    "formats_tested": "$(echo $FORMATS | tr ',' ' ')",
    "qualities_tested": "$(echo $QUALITIES | tr ',' ' ')"
  },
  "results": [
$all_results
  ],
  "summary": {
    "best_format": "TBD",
    "best_quality": "TBD",
    "best_compression_ratio": "TBD",
    "recommendations": []
  }
}
EOF

    log_info "Report saved to: $OUTPUT_FILE"
}

# ── Main Benchmark Suite ───────────────────────────────────────────────────────

run_benchmark() {
    log_info "Starting Image Compression Benchmark"
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     Image Compression Benchmark Suite                    ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Configuration:"
    log_info "  Converter URL: $CONVERTER_URL"
    log_info "  Test Image: $IMAGE_FILE"
    log_info "  Formats: $(echo $FORMATS | tr ',' ' ')"
    log_info "  Qualities: $(echo $QUALITIES | tr ',' ' ')"
    log_info "  Output: $OUTPUT_FILE"
    echo ""

    # Check prerequisites
    if [ ! -f "$IMAGE_FILE" ]; then
        log_error "Test image not found: $IMAGE_FILE"
        exit 1
    fi

    local original_size=$(stat -f%z "$IMAGE_FILE" 2>/dev/null || stat -c%s "$IMAGE_FILE" 2>/dev/null)
    log_info "Original image size: $original_size bytes"

    # Check converter accessibility
    log_info "Testing converter accessibility..."
    if ! curl -s --max-time 5 "${CONVERTER_URL}/health" &> /dev/null; then
        log_error "Converter not accessible at $CONVERTER_URL"
        exit 1
    fi
    log_success "Converter is accessible"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Parse formats and qualities
    IFS=',' read -ra FORMAT_ARRAY <<< "$FORMATS"
    IFS=',' read -ra QUALITY_ARRAY <<< "$QUALITIES"

    local all_results=""
    local result_count=0
    local best_format=""
    local best_quality=""
    local best_ratio=100
    local total_tests=${#FORMAT_ARRAY[@]} * ${#QUALITY_ARRAY[@]}

    echo ""
    log_info "Running $total_tests benchmark tests..."
    echo ""

    # Run benchmarks for each format and quality combination
    for format in "${FORMAT_ARRAY[@]}"; do
        log_format "Testing format: ${format^^}"
        local format_results=""

        for quality in "${QUALITY_ARRAY[@]}"; do
            printf "  Testing %-6s quality %-3s... " "$format" "$quality"

            local result=$(convert_and_measure "$format" "$quality" "$IMAGE_FILE")
            IFS=, read -r status duration original converted ratio http_code <<< "$result"

            if [ "$status" = "success" ]; then
                local time_ms=$(echo "$duration * 1000" | bc | cut -d'.' -f1)
                printf "${GREEN}✓${NC} %s (%s ms)\n" "$ratio" "$time_ms"

                # Track best result
                local ratio_num=$(echo "$ratio" | sed 's/%//g')
                if (( $(echo "$ratio_num < $best_ratio" | bc -l) )); then
                    best_ratio=$ratio_num
                    best_format=$format
                    best_quality=$quality
                fi

                # Add to results
                if [ -n "$all_results" ]; then
                    all_results="${all_results},"
                fi
                all_results="${all_results}
    {
      \"format\": \"$format\",
      \"quality\": $quality,
      \"original_bytes\": $original,
      \"converted_bytes\": $converted,
      \"compression_ratio\": \"$ratio\",
      \"duration_ms\": $(echo "$duration * 1000" | bc | cut -d'.' -f1),
      \"http_code\": $http_code
    }"
                result_count=$((result_count + 1))
            else
                printf "${RED}✗${NC} HTTP $http_code\n"
                log_verbose "Failed: $result"
            fi
        done
        echo ""
    done

    # Generate report
    log_info "Generating benchmark report..."
    generate_report "$all_results" "$original_size"

    # Display summary
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                    Benchmark Summary                     ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Best Compression:"
    echo "  Format:     ${best_format^^}"
    echo "  Quality:    $best_quality"
    echo "  Ratio:      ${best_ratio}%"
    echo ""

    if (( $(echo "$best_ratio < 50" | bc -l) )); then
        echo "  ${GREEN}Excellent compression!${NC}"
    elif (( $(echo "$best_ratio < 70" | bc -l) )); then
        echo "  ${BLUE}Good compression${NC}"
    else
        echo "  ${YELLOW}Consider lower quality settings${NC}"
    fi
    echo ""

    echo "Recommendations:"
    echo "  • For web: Use WebP at quality 80 (best compatibility/size ratio)"
    echo "  • For modern browsers: Use AVIF at quality 75 (best compression)"
    echo "  • For maximum compatibility: Use JPEG at quality 85"
    echo ""

    # Update report with recommendations
    if command -v jq &> /dev/null && [ -f "$OUTPUT_FILE" ]; then
        local tmp_file=$(mktemp)
        jq --arg bf "$best_format" --arg bq "$best_quality" --arg br "${best_ratio}%" \
            '.summary.best_format = $bf | .summary.best_quality = $bq | .summary.best_compression_ratio = $br' \
            "$OUTPUT_FILE" > "$tmp_file" && mv "$tmp_file" "$OUTPUT_FILE"
    fi

    log_success "Benchmark completed successfully!"
    echo ""
    log_info "Detailed results: $OUTPUT_FILE"
    log_info "Test images: $OUTPUT_DIR/"
}

# ── Visual Comparison (Optional) ───────────────────────────────────────────────

generate_visual_comparison() {
    log_info "Generating visual comparison table..."
    echo ""

    if [ ! -f "$OUTPUT_FILE" ] || ! command -v jq &> /dev/null; then
        log_warning "Cannot generate visual table (missing $OUTPUT_FILE or jq)"
        return
    fi

    echo "Format Comparison by Quality:"
    echo ""

    # Header
    printf "%-8s │" "Quality"
    for format in "${FORMAT_ARRAY[@]}"; do
        printf " %-15s │" "${format^^}"
    done
    echo ""
    echo "──────────┼$(printf '─────────────────┼' "${FORMAT_ARRAY[@]}")"

    # Data rows
    for quality in "${QUALITY_ARRAY[@]}"; do
        printf "%-8s │" "$quality"
        for format in "${FORMAT_ARRAY[@]}"; do
            local ratio=$(jq -r ".results[] | select(.quality == $quality and .format == \"$format\") | .compression_ratio" "$OUTPUT_FILE" 2>/dev/null || echo "N/A")
            printf " %-15s │" "$ratio"
        done
        echo ""
    fi
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
    run_benchmark
    generate_visual_comparison

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              Benchmark Complete!                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    log_success "All tests completed!"
}

main "$@"
