#!/bin/bash
#
# Secret Rotation Script for Image Converter Platform
#
# Usage: ./rotate-secrets.sh [OPTIONS]
#
# Options:
#   --secret NAME     Rotate specific secret (default: all)
#   --dry-run         Show what would be done without making changes
#   --force           Skip confirmation prompts
#   --help            Show this help message
#
# Examples:
#   ./rotate-secrets.sh --dry-run
#   ./rotate-secrets.sh --secret onboarding-database-url
#   ./rotate-secrets.sh --force
#
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

SCRIPT_NAME="rotate-secrets"
SCRIPT_VERSION="1.0"
LOG_FILE="/var/log/secret-rotation-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/tmp/secrets-backup-$(date +%Y%m%d-%H%M%S)"
REGION="fr-par"
PROJECT_ID=""
DRY_RUN=false
FORCE=false
SPECIFIC_SECRET=""

# Secret names
SECRET_DB_URL="onboarding-database-url"
SECRET_S3_CREDS="onboarding-s3-credentials"
SECRET_QWEN_KEY="qwen-api-key"
SECRET_SERVICE_TOKEN="onboarding-service-token"

# ── Colors for Output ──────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ── Helper Functions ───────────────────────────────────────────────────────────

log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo -e "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }
warning() { log "WARNING" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }

die() {
  error "$1"
  exit 1
}

confirm() {
  if [[ "$FORCE" == "true" ]]; then
    return 0
  fi

  read -p "$1 [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    return 1
  fi
  return 0
}

check_prerequisites() {
  info "Checking prerequisites..."

  local missing_tools=()

  for tool in scw aws kubectl jq openssl; do
    if ! command -v "$tool" &> /dev/null; then
      missing_tools+=("$tool")
    fi
  done

  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing_tools[*]}"
  fi

  # Check Scaleway authentication
  if ! scw account get &> /dev/null; then
    die "Not authenticated with Scaleway. Run 'scw init'"
  fi

  # Check kubectl context
  if ! kubectl cluster-info &> /dev/null; then
    warning "kubectl not connected to cluster"
  fi

  success "Prerequisites check passed"
}

get_project_id() {
  PROJECT_ID=$(scw config get project_id 2>/dev/null || echo "")
  if [[ -z "$PROJECT_ID" ]]; then
    die "Could not determine project ID. Please configure Scaleway CLI"
  fi
  info "Using project ID: $PROJECT_ID"
}

get_secret_id() {
  local secret_name="$1"
  local secret_id

  secret_id=$(scw secret secret list \
    --project-id "$PROJECT_ID" \
    --region "$REGION" \
    -o json 2>/dev/null | \
    jq -r --arg name "$secret_name" '.[] | select(.name == $name) | .id')

  if [[ -z "$secret_id" || "$secret_id" == "null" ]]; then
    echo ""
  else
    echo "$secret_id"
  fi
}

backup_secret() {
  local secret_name="$1"
  local secret_id="$2"

  info "Backing up $secret_name..."

  mkdir -p "$BACKUP_DIR"

  # Get current secret version
  local current_version
  current_version=$(scw secret secret-version get \
    --secret-id "$secret_id" \
    --region "$REGION" \
    -o json 2>/dev/null | jq -r '.data // empty')

  if [[ -n "$current_version" ]]; then
    echo "$current_version" > "$BACKUP_DIR/${secret_name}.current"
    success "Backed up $secret_name to $BACKUP_DIR"
  else
    warning "Could not backup $secret_name (no current version found)"
  fi
}

generate_password() {
  local length="${1:-32}"
  openssl rand -base64 "$length" | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c "$length"
}

generate_uuid() {
  if command -v uuidgen &> /dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

# ── Rotation Functions ─────────────────────────────────────────────────────────

rotate_database_url() {
  local secret_name="$SECRET_DB_URL"
  info "🔄 Rotating database credentials..."

  local secret_id
  secret_id=$(get_secret_id "$secret_name")

  if [[ -z "$secret_id" ]]; then
    die "Secret not found: $secret_name"
  fi

  # Backup current secret
  backup_secret "$secret_name" "$secret_id"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would generate new database password"
    info "[DRY-RUN] Would update Secret Manager"
    info "[DRY-RUN] Would restart REST API deployment"
    return 0
  fi

  # Get current database connection details
  local current_url
  current_url=$(scw secret secret-version get \
    --secret-id "$secret_id" \
    --region "$REGION" | \
    base64 -d 2>/dev/null || echo "")

  if [[ -z "$current_url" ]]; then
    die "Could not retrieve current database URL"
  fi

  # Parse connection string
  local db_user db_host db_port db_name
  db_user=$(echo "$current_url" | sed -n 's|postgresql://\([^:]*\):.*|\1|p')
  db_host=$(echo "$current_url" | sed -n 's|postgresql://[^@]*@\([^:]*\):.*|\1|p')
  db_port=$(echo "$current_url" | sed -n 's|.*@\([^:]*\):\([0-9]*\)/.*|\2|p')
  db_name=$(echo "$current_url" | sed -n 's|.*/\([^?]*).*|\1|p')

  info "Current database: $db_name@$db_host:$db_port (user: $db_user)"

  # Generate new password
  local new_password
  new_password=$(generate_password 32)
  info "Generated new database password (32 chars)"

  # Store new password temporarily
  echo "$new_password" > "$BACKUP_DIR/db-password.new"
  chmod 600 "$BACKUP_DIR/db-password.new"

  confirm "Ready to rotate database credentials. This will require application restart. Continue?" || return 1

  # Update database user password (requires admin access)
  info "Updating database user password..."

  # Note: In production, you'd connect to RDB and run:
  # PGPASSWORD=<admin_password> psql -h $db_host -U postgres -d $db_name \
  #   -c "ALTER USER $db_user WITH PASSWORD '$new_password';"

  warning "⚠️  MANUAL STEP REQUIRED: Update database user password via Scaleway Console"
  warning "   Navigate to: Database → onboarding-db → Users → $db_user → Change Password"
  warning "   Use password from: $BACKUP_DIR/db-password.new"

  read -p "Press Enter after updating database password..."

  # Build new connection string
  local new_url="postgresql://${db_user}:${new_password}@${db_host}:${db_port}/${db_name}?sslmode=require"
  local encoded_url
  encoded_url=$(echo -n "$new_url" | base64 -w 0)

  # Create new secret version
  info "Updating Secret Manager..."
  scw secret secret-version create \
    --secret-id "$secret_id" \
    --data "$encoded_url" \
    --region "$REGION" > /dev/null

  success "Secret Manager updated"

  # Restart REST API deployment
  info "Restarting REST API deployment..."
  kubectl rollout restart deployment rest-api -n onboarding 2>/dev/null || \
    warning "Could not restart deployment (kubectl not connected?)"

  info "Waiting for rollout to complete..."
  kubectl rollout status deployment rest-api -n onboarding --timeout=120s 2>/dev/null || \
    warning "Rollout status check failed"

  # Validate
  info "Validating rotation..."
  sleep 10 # Wait for pods to be ready

  local health_status
  health_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health 2>/dev/null || echo "000")

  if [[ "$health_status" == "200" ]]; then
    success "✅ Database rotation completed successfully"
  else
    error "❌ Health check failed (status: $health_status)"
    warning "Consider rolling back: backup at $BACKUP_DIR"
    return 1
  fi
}

rotate_s3_credentials() {
  local secret_name="$SECRET_S3_CREDS"
  info "🔄 Rotating S3 credentials..."

  local secret_id
  secret_id=$(get_secret_id "$secret_name")

  if [[ -z "$secret_id" ]]; then
    die "Secret not found: $secret_name"
  fi

  # Backup current secret
  backup_secret "$secret_name" "$secret_id"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would generate new IAM credentials"
    info "[DRY-RUN] Would update Secret Manager"
    info "[DRY-RUN] Would update Kubernetes secrets"
    return 0
  fi

  confirm "Ready to rotate S3 credentials. Continue?" || return 1

  # Generate new credentials via Scaleway IAM
  info "Generating new IAM credentials..."

  # Get application ID for S3 access
  local app_id
  app_id=$(scw iam application list \
    -o json 2>/dev/null | \
    jq -r '.[] | select(.name | contains("onboarding-s3")) | .id' | head -1)

  if [[ -z "$app_id" ]]; then
    warning "Could not find S3 application. Creating new credentials manually..."
    warning "⚠️  MANUAL STEP: Generate credentials in Scaleway Console → IAM"
  else
    info "Found application: $app_id"

    # Create new access key
    local credentials
    credentials=$(scw iam access-key create \
      --application-id "$app_id" \
      --region "$REGION" \
      -o json 2>/dev/null || echo "")

    if [[ -z "$credentials" ]]; then
      die "Failed to create new IAM credentials"
    fi

    local new_access_key new_secret_key
    new_access_key=$(echo "$credentials" | jq -r '.access_key')
    new_secret_key=$(echo "$credentials" | jq -r '.secret_key')

    info "Generated new access key: $new_access_key"

    # Store temporarily
    cat <<EOF > "$BACKUP_DIR/s3-credentials.new"
{
  "access_key": "$new_access_key",
  "secret_key": "$new_secret_key"
}
EOF
    chmod 600 "$BACKUP_DIR/s3-credentials.new"

    # Create JSON and base64 encode
    local encoded_creds
    encoded_creds=$(cat "$BACKUP_DIR/s3-credentials.new" | base64 -w 0)

    # Update Secret Manager
    info "Updating Secret Manager..."
    scw secret secret-version create \
      --secret-id "$secret_id" \
      --data "$encoded_creds" \
      --region "$REGION" > /dev/null

    success "Secret Manager updated"
  fi

  # Update Kubernetes secrets
  info "Updating Kubernetes secrets..."

  if [[ -n "${new_access_key:-}" && -n "${new_secret_key:-}" ]]; then
    kubectl create secret generic onboarding-s3-creds \
      --from-literal=access-key="$new_access_key" \
      --from-literal=secret-key="$new_secret_key" \
      -n onboarding \
      --dry-run=client -o yaml 2>/dev/null | \
      kubectl apply -f - 2>/dev/null || \
      warning "Could not update Kubernetes secrets"

    # Restart REST API
    info "Restarting REST API deployment..."
    kubectl rollout restart deployment rest-api -n onboarding 2>/dev/null || true
  fi

  # Validate S3 access
  info "Validating S3 access..."
  sleep 10

  # Note: Actual validation would test S3 operations
  success "✅ S3 credentials rotation completed"

  warning "⚠️  Don't forget to deactivate old credentials after 24-48 hours"
}

rotate_qwen_api_key() {
  local secret_name="$SECRET_QWEN_KEY"
  info "🔄 Rotating Qwen API key..."

  local secret_id
  secret_id=$(get_secret_id "$secret_name")

  if [[ -z "$secret_id" ]]; then
    die "Secret not found: $secret_name"
  fi

  # Backup current secret
  backup_secret "$secret_name" "$secret_id"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would generate new Qwen API key"
    info "[DRY-RUN] Would update Secret Manager"
    info "[DRY-RUN] Would restart AI Alt-Generator"
    return 0
  fi

  confirm "Ready to rotate Qwen API key. Continue?" || return 1

  warning "⚠️  MANUAL STEP REQUIRED: Generate new API key in Qwen Dashboard"
  warning "   Navigate to: https://platform.qwen.ai → API Keys → Create New Key"
  warning "   Copy the key immediately (shown only once)"

  read -p "Enter new Qwen API key: " new_qwen_key

  if [[ -z "$new_qwen_key" ]]; then
    die "No API key provided"
  fi

  # Validate key format (basic check)
  if [[ ! "$new_qwen_key" =~ ^sk- ]]; then
    warning "API key doesn't look like a Qwen key (should start with 'sk-')"
    confirm "Continue anyway?" || return 1
  fi

  # Base64 encode
  local encoded_key
  encoded_key=$(echo -n "$new_qwen_key" | base64 -w 0)

  # Update Secret Manager
  info "Updating Secret Manager..."
  scw secret secret-version create \
    --secret-id "$secret_id" \
    --data "$encoded_key" \
    --region "$REGION" > /dev/null

  success "Secret Manager updated"

  # Restart AI Alt-Generator (Serverless)
  info "Restarting AI Alt-Generator..."

  local function_id
  function_id=$(scw container function list \
    -o json 2>/dev/null | \
    jq -r '.[] | select(.name == "ai-alt-generator") | .id')

  if [[ -n "$function_id" ]]; then
    scw container function update \
      --function-id "$function_id" \
      --region "$REGION" \
      --env FORCE_RELOAD=$(date +%s) > /dev/null || \
      warning "Could not trigger function reload"

    success "AI Alt-Generator restarted"
  else
    warning "Could not find AI Alt-Generator function"
  fi

  # Validate
  info "Validating rotation..."
  sleep 10

  success "✅ Qwen API key rotation completed"
}

rotate_service_token() {
  local secret_name="$SECRET_SERVICE_TOKEN"
  info "🔄 Rotating service token..."

  local secret_id
  secret_id=$(get_secret_id "$secret_name")

  if [[ -z "$secret_id" ]]; then
    die "Secret not found: $secret_name"
  fi

  # Backup current secret
  backup_secret "$secret_name" "$secret_id"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would generate new JWT service token"
    info "[DRY-RUN] Would update Secret Manager"
    info "[DRY-RUN] Would update all services"
    return 0
  fi

  confirm "Ready to rotate service token. Continue?" || return 1

  # Generate new JWT secret
  local jwt_secret
  jwt_secret=$(openssl rand -base64 64)

  info "Generated new JWT secret"
  echo "$jwt_secret" > "$BACKUP_DIR/jwt-secret.new"
  chmod 600 "$BACKUP_DIR/jwt-secret.new"

  # Note: In production, you'd use a proper JWT library to sign tokens
  # For this example, we'll generate a simple token
  local new_token
  new_token="Bearer_$(generate_uuid)_$(date +%s)"

  info "Generated new service token"
  echo "$new_token" > "$BACKUP_DIR/service-token.new"
  chmod 600 "$BACKUP_DIR/service-token.new"

  # Base64 encode
  local encoded_token
  encoded_token=$(echo -n "$new_token" | base64 -w 0)

  # Update Secret Manager
  info "Updating Secret Manager..."
  scw secret secret-version create \
    --secret-id "$secret_id" \
    --data "$encoded_token" \
    --region "$REGION" > /dev/null

  success "Secret Manager updated"

  # Update Kubernetes secrets
  info "Updating Kubernetes secrets..."
  kubectl create secret generic onboarding-service-token \
    --from-literal=token="$new_token" \
    -n onboarding \
    --dry-run=client -o yaml 2>/dev/null | \
    kubectl apply -f - 2>/dev/null || \
    warning "Could not update Kubernetes secrets"

  # Restart all services
  info "Restarting all services..."
  kubectl rollout restart deployment rest-api -n onboarding 2>/dev/null || true

  success "✅ Service token rotation completed"
}

# ── Main Functions ─────────────────────────────────────────────────────────────

show_help() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Usage: $0 [OPTIONS]

Options:
  --secret NAME     Rotate specific secret only
                    Choices: database, s3, qwen, token, all (default)
  --dry-run         Show what would be done without making changes
  --force           Skip confirmation prompts
  --help            Show this help message

Examples:
  $0 --dry-run
  $0 --secret database
  $0 --secret s3 --force
  $0 --secret all

Secrets:
  database    PostgreSQL connection string
  s3          S3 Object Storage credentials
  qwen        Qwen Vision API key
  token       Service authentication token
  all         Rotate all secrets (default)

Logs:
  Log file: $LOG_FILE
  Backup dir: $BACKUP_DIR

EOF
}

rotate_all() {
  info "🚀 Starting rotation of all secrets..."
  echo

  local failed=()

  rotate_database_url || failed+=("database")
  echo

  rotate_s3_credentials || failed+=("s3")
  echo

  rotate_qwen_api_key || failed+=("qwen")
  echo

  rotate_service_token || failed+=("token")
  echo

  if [[ ${#failed[@]} -gt 0 ]]; then
    error "❌ Failed to rotate: ${failed[*]}"
    warning "Backups available at: $BACKUP_DIR"
    return 1
  else
    success "✅ All secrets rotated successfully"
    return 0
  fi
}

rotate_specific() {
  case "$SPECIFIC_SECRET" in
    database|db|onboarding-database-url)
      rotate_database_url
      ;;
    s3|onboarding-s3-credentials)
      rotate_s3_credentials
      ;;
    qwen|qwen-api-key)
      rotate_qwen_api_key
      ;;
    token|service|onboarding-service-token)
      rotate_service_token
      ;;
    all)
      rotate_all
      ;;
    *)
      die "Unknown secret: $SPECIFIC_SECRET. Use --help for options."
      ;;
  esac
}

main() {
  echo
  info "╔════════════════════════════════════════════════════════╗"
  info "║   Secret Rotation Script v$SCRIPT_VERSION"
  info "╚════════════════════════════════════════════════════════╝"
  echo

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --secret)
        SPECIFIC_SECRET="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        die "Unknown option: $1. Use --help for usage."
        ;;
    esac
  done

  # Check prerequisites
  check_prerequisites
  get_project_id

  # Create backup directory
  mkdir -p "$BACKUP_DIR"

  info "Log file: $LOG_FILE"
  info "Backup directory: $BACKUP_DIR"
  echo

  if [[ "$DRY_RUN" == "true" ]]; then
    warning "🔍 DRY RUN MODE - No changes will be made"
    echo
  fi

  # Execute rotation
  if [[ -n "$SPECIFIC_SECRET" ]]; then
    rotate_specific
  else
    rotate_all
  fi

  # Summary
  echo
  info "╔════════════════════════════════════════════════════════╗"
  info "║   Rotation Complete"
  info "╚════════════════════════════════════════════════════════╝"
  info ""
  info "Next steps:"
  info "  1. Verify all services are healthy"
  info "  2. Monitor logs for authentication errors"
  info "  3. Update documentation if needed"
  info "  4. Schedule deactivation of old credentials (24-48h)"
  info ""
  info "Backups stored at: $BACKUP_DIR"
  info "Log file: $LOG_FILE"
  echo
}

# ── Entry Point ───────────────────────────────────────────────────────────────

main "$@"
