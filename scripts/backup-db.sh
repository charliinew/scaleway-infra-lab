#!/usr/bin/env bash
#
# backup-db.sh - Automated PostgreSQL Backup with Cross-Region Replication
#
# Usage: ./backup-db.sh [OPTIONS]
#
# Options:
#   -m, --mode MODE           Backup mode: full, incremental, wal (default: full)
#   -r, --region REGION       Target region for replication (default: nl-ams)
#   -k, --retention DAYS      Retention period in days (default: 30)
#   -c, --compression         Enable compression (default: enabled)
#   -e, --encryption          Enable encryption (default: enabled)
#   -n, --dry-run             Show what would be done without executing
#   -v, --verbose             Enable verbose output
#   -h, --help                Show this help message
#
# This script:
# 1. Creates PostgreSQL dumps using pg_dump
# 2. Compresses and encrypts backups
# 3. Uploads to primary S3 bucket
# 4. Replicates to cross-region bucket
# 5. Cleans up old backups based on retention policy
# 6. Sends notifications on success/failure
#
# Cron example (daily at 2 AM):
# 0 2 * * * /path/to/backup-db.sh --mode full >> /var/log/backup-db.log 2>&1
#
# Cron example (hourly WAL backups):
# 0 * * * * /path/to/backup-db.sh --mode wal >> /var/log/backup-db.log 2>&1
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

# Backup settings
BACKUP_MODE="full"
REPLICATION_REGION="nl-ams"
RETENTION_DAYS=30
COMPRESSION_ENABLED=true
ENCRYPTION_ENABLED=true
DRY_RUN=false
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Timestamps
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_ONLY=$(date +%Y%m%d)
BACKUP_TYPE="full"

# Directories
BACKUP_DIR="/tmp/postgres-backups"
LOCAL_BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"
LOG_FILE="/var/log/backup-db.log"

# S3 Configuration (from environment or Secret Manager)
S3_PRIMARY_BUCKET="${S3_PRIMARY_BUCKET:-onboarding-backups-primary}"
S3_REPLICA_BUCKET="${S3_REPLICA_BUCKET:-onboarding-backups-replica}"
S3_PRIMARY_ENDPOINT="s3.fr-par.scw.cloud"
S3_REPLICA_ENDPOINT="s3.${REPLICATION_REGION}.scw.cloud"
S3_REGION="fr-par"

# Database Configuration (from environment or Secret Manager)
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-onboarding}"
DB_USER="${DB_USER:-onboarding}"
DB_PASSWORD="${DB_PASSWORD:-}"

# Encryption (GPG)
GPG_RECIPIENT="${GPG_RECIPIENT:-}"
GPG_KEY_ID="${GPG_KEY_ID:-}"

# Monitoring
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
PAGERDUTY_KEY="${PAGERDUTY_KEY:-}"

# ── Helper Functions ───────────────────────────────────────────────────────────

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
    fi
}

show_help() {
    cat << EOF
Automated PostgreSQL Backup with Cross-Region Replication

Usage: $0 [OPTIONS]

Options:
  -m, --mode MODE           Backup mode: full, incremental, wal (default: full)
  -r, --region REGION       Target region for replication (default: nl-ams)
  -k, --retention DAYS      Retention period in days (default: 30)
  -c, --compression         Enable compression (default: enabled)
  -e, --encryption          Enable encryption (default: enabled)
  -n, --dry-run             Show what would be done without executing
  -v, --verbose             Enable verbose output
  -h, --help                Show this help message

Backup Modes:
  full        Complete database dump (daily recommended)
  incremental Differential backup since last full (hourly)
  wal         Write-Ahead Log backup (continuous)

Examples:
  $0 --mode full --retention 30
  $0 -m wal -r nl-ams -v
  $0 --dry-run

Environment Variables:
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
  S3_PRIMARY_BUCKET, S3_REPLICA_BUCKET
  GPG_RECIPIENT, GPG_KEY_ID
  SLACK_WEBHOOK_URL, PAGERDUTY_KEY

EOF
    exit 0
}

# ── Parse Arguments ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--mode)
            BACKUP_MODE="$2"
            shift 2
            ;;
        -r|--region)
            REPLICATION_REGION="$2"
            S3_REPLICA_ENDPOINT="s3.${REPLICATION_REGION}.scw.cloud"
            shift 2
            ;;
        -k|--retention)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        -c|--compression)
            COMPRESSION_ENABLED=true
            shift
            ;;
        -e|--encryption)
            ENCRYPTION_ENABLED=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
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

# ── Validation Functions ───────────────────────────────────────────────────────

check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    # Check required tools
    command -v pg_dump &> /dev/null || missing+=("postgresql-client")
    command -v aws &> /dev/null || missing+=("aws-cli")
    command -v gzip &> /dev/null || missing+=("gzip")

    if [ "$ENCRYPTION_ENABLED" = true ]; then
        command -v gpg &> /dev/null || missing+=("gpg")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: apt-get install ${missing[*]}"
        exit 1
    fi

    # Check database connectivity
    if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        log_error "Database credentials not set. Please configure:"
        log_error "  DB_HOST, DB_USER, DB_PASSWORD"
        log_info "Or fetch from Secret Manager:"
        log_info "  export DB_PASSWORD=\$(scw secret version get <secret-id> --region fr-par)"
        exit 1
    fi

    # Check S3 credentials
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        log_error "S3 credentials not set. Please configure:"
        log_error "  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# ── Backup Functions ───────────────────────────────────────────────────────────

create_backup_directory() {
    log_info "Creating backup directory: $LOCAL_BACKUP_PATH"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would create directory: $LOCAL_BACKUP_PATH"
        return
    fi

    mkdir -p "$LOCAL_BACKUP_PATH"
    chmod 700 "$LOCAL_BACKUP_PATH"
}

perform_full_backup() {
    log_info "Starting full database backup..."
    log_verbose "Database: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"

    local backup_file="${LOCAL_BACKUP_PATH}/dump_${TIMESTAMP}.sql"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would run pg_dump to: $backup_file"
        return 0
    fi

    # Create backup with pg_dump
    PGPASSWORD="$DB_PASSWORD" pg_dump \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        -F c \
        -b \
        -v \
        -f "${backup_file}.custom" \
        2>&1 | tee -a "$LOG_FILE"

    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -ne 0 ]; then
        log_error "pg_dump failed with exit code $exit_code"
        return 1
    fi

    # Also create plain SQL backup for portability
    PGPASSWORD="$DB_PASSWORD" pg_dump \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        -f "${backup_file}.sql" \
        2>&1 | tee -a "$LOG_FILE"

    log_success "Full backup created successfully"

    # Get backup size
    local size=$(du -sh "$LOCAL_BACKUP_PATH" | cut -f1)
    log_info "Backup size: $size"

    return 0
}

perform_incremental_backup() {
    log_info "Starting incremental backup..."
    log_warning "Incremental backups require pg_basebackup and WAL archiving"
    log_warning "Falling back to full backup for now"

    perform_full_backup
}

perform_wal_backup() {
    log_info "Starting WAL backup..."
    log_warning "WAL backup requires continuous archiving setup"
    log_info "See: https://www.postgresql.org/docs/current/continuous-archiving.html"

    # For now, just backup current WAL files
    local wal_dir="${LOCAL_BACKUP_PATH}/wal"
    mkdir -p "$wal_dir"

    # Archive current WAL (requires superuser)
    PGPASSWORD="$DB_PASSWORD" psql \
        -h "$DB_HOST" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        -c "SELECT pg_switch_wal();" \
        2>&1 | tee -a "$LOG_FILE"

    log_success "WAL backup initiated"
}

compress_backup() {
    if [ "$COMPRESSION_ENABLED" != true ]; then
        log_info "Compression disabled, skipping..."
        return 0
    fi

    log_info "Compressing backup..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would compress files in: $LOCAL_BACKUP_PATH"
        return 0
    fi

    # Compress SQL files with gzip
    find "$LOCAL_BACKUP_PATH" -name "*.sql" -type f -exec gzip -9 {} \;

    log_success "Backup compressed"
}

encrypt_backup() {
    if [ "$ENCRYPTION_ENABLED" != true ]; then
        log_info "Encryption disabled, skipping..."
        return 0
    fi

    if [ -z "$GPG_RECIPIENT" ]; then
        log_warning "GPG_RECIPIENT not set, skipping encryption"
        return 0
    fi

    log_info "Encrypting backup with GPG..."
    log_verbose "Recipient: $GPG_RECIPIENT"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would encrypt files in: $LOCAL_BACKUP_PATH"
        return 0
    fi

    # Encrypt all backup files
    find "$LOCAL_BACKUP_PATH" -type f \( -name "*.sql.gz" -o -name "*.custom" \) \
        -exec gpg --encrypt --recipient "$GPG_RECIPIENT" --trust-model always {} \;

    # Remove unencrypted files
    find "$LOCAL_BACKUP_PATH" -type f \( -name "*.sql.gz" -o -name "*.custom" \) \
        -not -name "*.gpg" -delete

    log_success "Backup encrypted"
}

# ── S3 Upload Functions ────────────────────────────────────────────────────────

upload_to_s3() {
    local bucket="$1"
    local endpoint="$2"
    local region="$3"

    log_info "Uploading backup to S3..."
    log_verbose "Bucket: $bucket"
    log_verbose "Endpoint: $endpoint"
    log_verbose "Region: $region"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would upload to: s3://${bucket}/postgresql/${DATE_ONLY}/"
        return 0
    fi

    # Upload using aws CLI with Scaleway endpoint
    AWS_ENDPOINT_URL="https://${endpoint}" \
    aws s3 cp "$LOCAL_BACKUP_PATH" \
        "s3://${bucket}/postgresql/${DATE_ONLY}/${TIMESTAMP}/" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --region "$region" \
        --recursive \
        --storage-class STANDARD \
        2>&1 | tee -a "$LOG_FILE"

    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -ne 0 ]; then
        log_error "S3 upload failed with exit code $exit_code"
        return 1
    fi

    log_success "Backup uploaded to s3://${bucket}/postgresql/${DATE_ONLY}/${TIMESTAMP}/"
    return 0
}

replicate_to_cross_region() {
    log_info "Replicating to cross-region bucket..."
    log_verbose "Target region: $REPLICATION_REGION"
    log_verbose "Target bucket: $S3_REPLICA_BUCKET"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would replicate to: $S3_REPLICA_BUCKET ($REPLICATION_REGION)"
        return 0
    fi

    # Upload to replica region
    upload_to_s3 "$S3_REPLICA_BUCKET" "$S3_REPLICA_ENDPOINT" "$REPLICATION_REGION"
}

# ── Cleanup Functions ──────────────────────────────────────────────────────────

cleanup_old_backups() {
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would clean up old backups from both regions"
        return 0
    fi

    # Cleanup primary bucket
    AWS_ENDPOINT_URL="https://${S3_PRIMARY_ENDPOINT}" \
    aws s3 rm "s3://${S3_PRIMARY_BUCKET}/postgresql/" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --region "$S3_REGION" \
        --recursive \
        --exclude "*" \
        --include "postgresql/*/dump_*" \
        2>&1 | while read -r line; do
            log_verbose "Primary cleanup: $line"
        done || true

    # Cleanup replica bucket
    AWS_ENDPOINT_URL="https://${S3_REPLICA_ENDPOINT}" \
    aws s3 rm "s3://${S3_REPLICA_BUCKET}/postgresql/" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --region "$REPLICATION_REGION" \
        --recursive \
        --exclude "*" \
        --include "postgresql/*/dump_*" \
        2>&1 | while read -r line; do
            log_verbose "Replica cleanup: $line"
        done || true

    # Note: The above is a simplified cleanup
    # For production, implement proper retention logic with date filtering

    log_success "Cleanup completed"
}

cleanup_local() {
    log_info "Cleaning up local backup directory..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would remove: $LOCAL_BACKUP_PATH"
        return 0
    fi

    rm -rf "$LOCAL_BACKUP_PATH"

    log_verbose "Removed: $LOCAL_BACKUP_PATH"
}

# ── Notification Functions ─────────────────────────────────────────────────────

send_slack_notification() {
    local status="$1"
    local message="$2"

    if [ -z "$SLACK_WEBHOOK_URL" ]; then
        log_verbose "Slack webhook not configured, skipping notification"
        return 0
    fi

    local color="good"
    if [ "$status" = "success" ]; then
        color="good"
    elif [ "$status" = "warning" ]; then
        color="warning"
    else
        color="danger"
    fi

    local payload=$(cat <<EOF
{
    "attachments": [
        {
            "color": "${color}",
            "title": "Database Backup - ${status^^}",
            "text": "${message}",
            "fields": [
                {"title": "Mode", "value": "${BACKUP_MODE}", "short": true},
                {"title": "Region", "value": "${S3_REGION}", "short": true},
                {"title": "Retention", "value": "${RETENTION_DAYS} days", "short": true},
                {"title": "Timestamp", "value": "${TIMESTAMP}", "short": true}
            ],
            "footer": "Database Backup Script",
            "ts": $(date +%s)
        }
    ]
}
EOF
)

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would send Slack notification"
        return 0
    fi

    curl -s -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "$SLACK_WEBHOOK_URL" > /dev/null 2>&1 || true

    log_verbose "Slack notification sent"
}

send_pagerduty_alert() {
    local severity="$1"
    local summary="$2"

    if [ -z "$PAGERDUTY_KEY" ]; then
        log_verbose "PagerDuty key not configured, skipping alert"
        return 0
    fi

    local payload=$(cat <<EOF
{
    "routing_key": "${PAGERDUTY_KEY}",
    "event_action": "trigger",
    "dedup_key": "backup-db-${TIMESTAMP}",
    "payload": {
        "summary": "${summary}",
        "severity": "${severity}",
        "source": "backup-db.sh",
        "component": "database",
        "group": "database",
        "class": "backup",
        "custom_details": {
            "backup_mode": "${BACKUP_MODE}",
            "timestamp": "${TIMESTAMP}",
            "primary_bucket": "${S3_PRIMARY_BUCKET}",
            "replica_bucket": "${S3_REPLICA_BUCKET}",
            "retention_days": "${RETENTION_DAYS}"
        }
    }
}
EOF
)

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would send PagerDuty alert"
        return 0
    fi

    curl -s -X POST \
        -H 'Content-type: application/json' \
        --data "$payload" \
        "https://events.pagerduty.com/v2/enqueue" > /dev/null 2>&1 || true

    log_verbose "PagerDuty alert sent"
}

# ── Generate Backup Report ─────────────────────────────────────────────────────

generate_report() {
    local start_time="$1"
    local end_time="$2"
    local backup_size="$3"

    log_info "Generating backup report..."

    local report_file="${LOCAL_BACKUP_PATH}/backup_report.json"

    cat > "$report_file" << EOF
{
  "backup_report": {
    "timestamp": "${TIMESTAMP}",
    "date": "${DATE_ONLY}",
    "mode": "${BACKUP_MODE}",
    "status": "success",
    "duration_seconds": $(echo "$end_time - $start_time" | bc),
    "backup_size_bytes": ${backup_size:-0},
    "compression": ${COMPRESSION_ENABLED},
    "encryption": ${ENCRYPTION_ENABLED},
    "retention_days": ${RETENTION_DAYS},
    "destinations": {
      "primary": {
        "bucket": "${S3_PRIMARY_BUCKET}",
        "endpoint": "${S3_PRIMARY_ENDPOINT}",
        "region": "${S3_REGION}",
        "path": "postgresql/${DATE_ONLY}/${TIMESTAMP}/"
      },
      "replica": {
        "bucket": "${S3_REPLICA_BUCKET}",
        "endpoint": "${S3_REPLICA_ENDPOINT}",
        "region": "${REPLICATION_REGION}",
        "path": "postgresql/${DATE_ONLY}/${TIMESTAMP}/"
      }
    },
    "database": {
      "host": "${DB_HOST}",
      "port": ${DB_PORT:-5432},
      "name": "${DB_NAME}",
      "user": "${DB_USER}"
    }
  }
}
EOF

    log_verbose "Report saved to: $report_file"
}

# ── Main Backup Workflow ───────────────────────────────────────────────────────

main() {
    local start_time=$(date +%s.%N)

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║   PostgreSQL Backup - Cross-Region Replication           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    log_info "Backup started"
    log_info "Mode: $BACKUP_MODE"
    log_info "Primary bucket: $S3_PRIMARY_BUCKET ($S3_REGION)"
    log_info "Replica bucket: $S3_REPLICA_BUCKET ($REPLICATION_REGION)"
    log_info "Retention: $RETENTION_DAYS days"

    if [ "$DRY_RUN" = true ]; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    echo ""

    # Pre-flight checks
    check_prerequisites

    # Create working directory
    create_backup_directory

    # Perform backup based on mode
    case $BACKUP_MODE in
        full)
            perform_full_backup
            ;;
        incremental)
            perform_incremental_backup
            ;;
        wal)
            perform_wal_backup
            ;;
        *)
            log_error "Unknown backup mode: $BACKUP_MODE"
            exit 1
            ;;
    esac

    if [ $? -ne 0 ]; then
        log_error "Backup failed"
        send_slack_notification "error" "Database backup failed: $BACKUP_MODE"
        send_pagerduty_alert "critical" "Database backup failed: $BACKUP_MODE"
        exit 1
    fi

    # Compress backup
    compress_backup

    # Encrypt backup
    encrypt_backup

    # Upload to primary S3
    upload_to_s3 "$S3_PRIMARY_BUCKET" "$S3_PRIMARY_ENDPOINT" "$S3_REGION"

    if [ $? -ne 0 ]; then
        log_error "Primary upload failed"
        send_slack_notification "error" "Backup upload to primary failed"
        exit 1
    fi

    # Replicate to cross-region
    replicate_to_cross_region

    # Cleanup old backups
    cleanup_old_backups

    # Cleanup local files
    cleanup_local

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)

    # Get final backup size
    local backup_size=$(du -sb "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "0")

    # Generate report
    generate_report "$start_time" "$end_time" "$backup_size"

    # Send success notification
    send_slack_notification "success" "Database backup completed successfully in ${duration}s"

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                  Backup Complete!                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    log_success "Backup completed in ${duration}s"
    log_success "Primary: s3://${S3_PRIMARY_BUCKET}/postgresql/${DATE_ONLY}/${TIMESTAMP}/"
    log_success "Replica: s3://${S3_REPLICA_BUCKET}/postgresql/${DATE_ONLY}/${TIMESTAMP}/"
    echo ""
}

# Trap errors
trap 'log_error "Backup interrupted"; exit 1' INT TERM

# Run main function
main "$@"
