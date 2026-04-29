#!/bin/bash
#
# S3 Cross-Region Backup Script
# ================================
# Backs up objects from primary S3 bucket (fr-par) to DR bucket (nl-ams)
#
# Usage: ./backup-s3.sh [--dry-run] [--verify] [--cleanup]
#
# Options:
#   --dry-run    Show what would be transferred without copying
#   --verify     Verify backup integrity after sync
#   --cleanup    Remove backups older than retention period
#   --help       Show this help message
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Sync failed
#   3 - Verification failed
#
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

# Bucket configuration (can be overridden via environment variables)
SOURCE_BUCKET="${S3_SOURCE_BUCKET:-onboarding-images-prod}"
DEST_BUCKET="${S3_DEST_BUCKET:-onboarding-images-dr}"
SOURCE_REGION="${S3_SOURCE_REGION:-fr-par}"
DEST_REGION="${S3_DEST_REGION:-nl-ams}"

# Scaleway S3 endpoints
SOURCE_ENDPOINT="https://s3.${SOURCE_REGION}.scw.cloud"
DEST_ENDPOINT="https://s3.${DEST_REGION}.scw.cloud"

# Backup configuration
RETENTION_DAYS="${S3_RETENTION_DAYS:-7}"
BACKUP_PREFIX="backup-archive"
LOG_DIR="/var/log/s3-backup"
LOCK_FILE="/tmp/s3-backup.lock"

# AWS CLI configuration (Scaleway-compatible)
export AWS_ENDPOINT_URL="${SOURCE_ENDPOINT}"
export AWS_ACCESS_KEY_ID="${ONBOARDING_ACCESS_KEY:-}"
export AWS_SECRET_ACCESS_KEY="${ONBOARDING_SECRET_KEY:-}"

# ── Colors & Logging ────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LOG_FILE="${LOG_DIR}/backup-$(date +%Y%m%d-%H%M%S).log"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" | tee -a "$LOG_FILE" >&2
}

# ── Helper Functions ───────────────────────────────────────────────────────────

show_help() {
    cat << EOF
S3 Cross-Region Backup Script
==============================

Usage: $0 [OPTIONS]

Options:
  --dry-run    Show what would be transferred without copying
  --verify     Verify backup integrity after sync
  --cleanup    Remove backups older than retention period (${RETENTION_DAYS} days)
  --help       Show this help message

Environment Variables:
  S3_SOURCE_BUCKET      Source bucket name (default: onboarding-images-prod)
  S3_DEST_BUCKET        Destination bucket name (default: onboarding-images-dr)
  S3_SOURCE_REGION      Source region (default: fr-par)
  S3_DEST_REGION        Destination region (default: nl-ams)
  S3_RETENTION_DAYS     Backup retention in days (default: 7)
  ONBOARDING_ACCESS_KEY  S3 access key (required)
  ONBOARDING_SECRET_KEY  S3 secret key (required)

Examples:
  # Run full backup with verification
  $0 --verify

  # Dry run to see what would be transferred
  $0 --dry-run

  # Backup and cleanup old files
  $0 --verify --cleanup

Exit Codes:
  0 - Success
  1 - General error
  2 - Sync failed
  3 - Verification failed
EOF
    exit 0
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi

    # Check credentials are set
    if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
        log_error "S3 credentials not set. Please set ONBOARDING_ACCESS_KEY and ONBOARDING_SECRET_KEY"
        exit 1
    fi

    # Check source bucket exists
    if ! aws s3 ls "s3://${SOURCE_BUCKET}/" --endpoint-url "$SOURCE_ENDPOINT" &> /dev/null; then
        log_error "Source bucket 's3://${SOURCE_BUCKET}' does not exist or is not accessible"
        exit 1
    fi

    # Check destination bucket exists
    if ! aws s3 ls "s3://${DEST_BUCKET}/" --endpoint-url "$DEST_ENDPOINT" &> /dev/null; then
        log_error "Destination bucket 's3://${DEST_BUCKET}' does not exist or is not accessible"
        exit 1
    fi

    # Create log directory
    mkdir -p "$LOG_DIR"

    log_success "Prerequisites check passed"
}

acquire_lock() {
    # Prevent concurrent backups
    if [[ -f "$LOCK_FILE" ]]; then
        pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log_error "Another backup process is running (PID: $pid)"
            exit 1
        else
            log_warning "Stale lock file found, removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# ── Backup Functions ───────────────────────────────────────────────────────────

sync_buckets() {
    local dry_run="${1:-false}"
    local dry_run_flag=""

    if [[ "$dry_run" == "true" ]]; then
        dry_run_flag="--dryrun"
        log_info "DRY RUN MODE - No files will be transferred"
    fi

    log_info "Starting S3 sync from '${SOURCE_BUCKET}' (${SOURCE_REGION}) to '${DEST_BUCKET}' (${DEST_REGION})"
    log_info "Source endpoint: $SOURCE_ENDPOINT"
    log_info "Destination endpoint: $DEST_ENDPOINT"

    # Get source bucket stats before sync
    local source_count
    source_count=$(aws s3 ls "s3://${SOURCE_BUCKET}/" \
        --endpoint-url "$SOURCE_ENDPOINT" \
        --recursive 2>/dev/null | wc -l)

    log_info "Source bucket contains $source_count objects"

    # Perform sync
    log_info "Syncing objects..."

    if aws s3 sync \
        "s3://${SOURCE_BUCKET}/" \
        "s3://${DEST_BUCKET}/" \
        --endpoint-url "$SOURCE_ENDPOINT" \
        --source-region "$SOURCE_REGION" \
        --region "$DEST_REGION" \
        --storage-class STANDARD \
        --only-show-errors \
        $dry_run_flag 2>&1 | tee -a "$LOG_FILE"; then

        log_success "Sync completed successfully"
    else
        log_error "Sync failed"
        return 2
    fi

    # Get destination bucket stats after sync
    local dest_count
    dest_count=$(aws s3 ls "s3://${DEST_BUCKET}/" \
        --endpoint-url "$DEST_ENDPOINT" \
        --recursive 2>/dev/null | wc -l)

    log_info "Destination bucket now contains $dest_count objects"

    # Store counts for verification
    echo "$source_count" > /tmp/s3_backup_source_count
    echo "$dest_count" > /tmp/s3_backup_dest_count

    return 0
}

verify_backup() {
    log_info "Verifying backup integrity..."

    local source_count dest_count

    if [[ -f /tmp/s3_backup_source_count ]]; then
        source_count=$(cat /tmp/s3_backup_source_count)
    else
        source_count=$(aws s3 ls "s3://${SOURCE_BUCKET}/" \
            --endpoint-url "$SOURCE_ENDPOINT" \
            --recursive 2>/dev/null | wc -l)
    fi

    dest_count=$(aws s3 ls "s3://${DEST_BUCKET}/" \
        --endpoint-url "$DEST_ENDPOINT" \
        --recursive 2>/dev/null | wc -l)

    log_info "Source count: $source_count"
    log_info "Destination count: $dest_count"

    # Calculate difference (allow 1% tolerance for in-flight uploads)
    local tolerance=$((source_count / 100 + 1))
    local diff=$((source_count - dest_count))

    if [[ $diff -lt 0 ]]; then
        diff=$((-diff))
    fi

    if [[ $diff -le $tolerance ]]; then
        log_success "Backup verification passed (difference: $diff, tolerance: $tolerance)"
        return 0
    else
        log_error "Backup verification failed (difference: $diff exceeds tolerance: $tolerance)"
        return 3
    fi
}

cleanup_old_backups() {
    log_info "Cleaning up backups older than ${RETENTION_DAYS} days..."

    local deleted_count=0
    local cutoff_date
    cutoff_date=$(date -d "${RETENTION_DAYS} days ago" +%s)

    # List and delete old backup files
    aws s3 ls "s3://${DEST_BUCKET}/${BACKUP_PREFIX}/" \
        --endpoint-url "$DEST_ENDPOINT" \
        --recursive 2>/dev/null | while read -r line; do
        local file_date file_size file_path

        # Parse AWS CLI output
        file_date=$(echo "$line" | awk '{print $1, $2}')
        file_size=$(echo "$line" | awk '{print $3}')
        file_path=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf $i" "; print ""}' | xargs)

        # Skip if not a valid file entry
        [[ -z "$file_date" || -z "$file_path" ]] && continue

        # Convert to timestamp
        local file_timestamp
        file_timestamp=$(date -d "$file_date" +%s 2>/dev/null) || continue

        # Check age
        local age_days=$(( (cutoff_date - file_timestamp) / 86400 ))

        if [[ $age_days -gt $RETENTION_DAYS ]]; then
            log_info "Deleting: $file_path (age: ${age_days} days)"

            aws s3 rm "s3://${DEST_BUCKET}/${file_path}" \
                --endpoint-url "$DEST_ENDPOINT" \
                &> /dev/null && ((deleted_count++)) || true
        fi
    done

    log_success "Cleanup complete (deleted: $deleted_count files)"
}

generate_report() {
    local sync_result=$1
    local verify_result=$2

    log_info "Generating backup report..."

    cat << EOF | tee -a "$LOG_FILE"

================================================================================
                         S3 BACKUP REPORT
================================================================================
Timestamp:        $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Source Bucket:    ${SOURCE_BUCKET} (${SOURCE_REGION})
Dest Bucket:      ${DEST_BUCKET} (${DEST_REGION})
Retention:        ${RETENTION_DAYS} days
--------------------------------------------------------------------------------
Source Objects:   $(cat /tmp/s3_backup_source_count 2>/dev/null || echo "N/A")
Dest Objects:     $(cat /tmp/s3_backup_dest_count 2>/dev/null || echo "N/A")
Sync Status:      $(if [[ $sync_result -eq 0 ]]; then echo "✅ SUCCESS"; else echo "❌ FAILED"; fi)
Verify Status:    $(if [[ $verify_result -eq 0 ]]; then echo "✅ PASSED"; elif [[ $verify_result -eq 3 ]]; then echo "❌ FAILED"; else echo "⏭️  SKIPPED"; fi)
Log File:         ${LOG_FILE}
================================================================================
EOF

    # Cleanup temp files
    rm -f /tmp/s3_backup_source_count /tmp/s3_backup_dest_count
}

send_notification() {
    local status=$1
    local message=$2

    # Slack notification (optional - configure via environment)
    if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        local color="good"
        [[ $status -ne 0 ]] && color="danger"

        curl -s -X POST -H 'Content-type: application/json' \
            --data "{
                \"attachments\": [{
                    \"color\": \"${color}\",
                    \"title\": \"S3 Backup ${status:+Failed}${status:-Completed}\",
                    \"text\": \"${message}\",
                    \"fields\": [
                        {\"title\": \"Source\", \"value\": \"${SOURCE_BUCKET}\", \"short\": true},
                        {\"title\": \"Destination\", \"value\": \"${DEST_BUCKET}\", \"short\": true},
                        {\"title\": \"Region\", \"value\": \"${SOURCE_REGION} → ${DEST_REGION}\", \"short\": true},
                        {\"title\": \"Timestamp\", \"value\": \"$(date -u +'%Y-%m-%d %H:%M:%S UTC')\", \"short\": false}
                    ]
                }]
            }" \
            "$SLACK_WEBHOOK_URL" > /dev/null 2>&1 || true
    fi
}

# ── Main Execution ─────────────────────────────────────────────────────────────

main() {
    local dry_run=false
    local verify=false
    local cleanup=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                dry_run=true
                shift
                ;;
            --verify)
                verify=true
                shift
                ;;
            --cleanup)
                cleanup=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Acquire lock
    acquire_lock

    log_info "=========================================="
    log_info "S3 Cross-Region Backup Starting"
    log_info "=========================================="

    # Check prerequisites
    check_prerequisites

    local sync_result=0
    local verify_result=1

    # Perform sync
    if sync_buckets "$dry_run"; then
        sync_result=0
    else
        sync_result=$?
        log_error "Backup sync failed with exit code $sync_result"
        send_notification "$sync_result" "Backup sync failed"
        exit "$sync_result"
    fi

    # Verify if requested
    if [[ "$verify" == "true" ]]; then
        if verify_backup; then
            verify_result=0
        else
            verify_result=$?
            log_warning "Backup verification failed"
        fi
    fi

    # Cleanup if requested
    if [[ "$cleanup" == "true" ]]; then
        cleanup_old_backups
    fi

    # Generate report
    generate_report "$sync_result" "$verify_result"

    # Send notification
    if [[ $verify_result -eq 0 || $verify_result -eq 1 ]]; then
        send_notification 0 "Backup completed successfully"
    else
        send_notification 3 "Backup verification failed"
    fi

    log_success "=========================================="
    log_success "S3 Cross-Region Backup Complete"
    log_success "=========================================="

    # Exit with appropriate code
    if [[ $verify_result -eq 3 ]]; then
        exit 3
    fi

    exit 0
}

# Run main function
main "$@"
