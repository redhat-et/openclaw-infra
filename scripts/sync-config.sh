#!/usr/bin/env bash
# ============================================================================
# SYNC CONFIG
# ============================================================================
# Captures the live openclaw.json from the running pod and updates the
# ConfigMap so that restarts (init container) preserve UI changes.
#
# The gateway writes config changes to the PVC, but the init container
# overwrites the PVC from the ConfigMap on every start. This script
# bridges that gap by syncing PVC → ConfigMap.
#
# Usage:
#   ./scripts/sync-config.sh                     # OpenShift (default)
#   ./scripts/sync-config.sh --k8s               # Vanilla Kubernetes
#   ./scripts/sync-config.sh --export-only       # Save to file, don't update ConfigMap
#   ./scripts/sync-config.sh --env-file .env.dev  # Custom .env
#
# Output: Also saves a copy to generated/ for reference.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
K8S_MODE=false
EXPORT_ONLY=false
ENV_FILE=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s) K8S_MODE=true; shift ;;
    --export-only) EXPORT_ONLY=true; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if $K8S_MODE; then
  KUBECTL="kubectl"
else
  KUBECTL="oc"
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

# Load .env
if [ ! -f "$ENV_FILE" ]; then
  log_error "No .env file found at $ENV_FILE. Run setup.sh first."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

if [ -z "${OPENCLAW_NAMESPACE:-}" ]; then
  log_error "OPENCLAW_NAMESPACE not set. Run setup.sh first."
  exit 1
fi

# Verify cluster connection
if ! $KUBECTL get namespace "$OPENCLAW_NAMESPACE" &>/dev/null; then
  log_error "Namespace $OPENCLAW_NAMESPACE not found."
  exit 1
fi

echo ""
log_info "Syncing live config from pod in $OPENCLAW_NAMESPACE..."

# Export live config from pod
LIVE_CONFIG=$($KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
  cat /home/node/.openclaw/openclaw.json 2>/dev/null) || {
  log_error "Could not read live config from pod. Is OpenClaw running?"
  exit 1
}

# Validate it's valid JSON
if ! echo "$LIVE_CONFIG" | python3 -m json.tool > /dev/null 2>&1; then
  log_warn "Live config is not valid JSON — saving raw content anyway"
fi

# Save local copy
GENERATED_DIR="$REPO_ROOT/generated"
mkdir -p "$GENERATED_DIR"
EXPORT_FILE="$GENERATED_DIR/openclaw-config-live.json"
echo "$LIVE_CONFIG" > "$EXPORT_FILE"
log_success "Saved to $EXPORT_FILE"

if $EXPORT_ONLY; then
  echo ""
  log_info "Export-only mode — ConfigMap not updated."
  log_info "To diff against current manifest:"
  echo "  diff <(python3 -m json.tool $EXPORT_FILE) <(python3 -m json.tool generated/agents/openclaw/overlays/*/config-patch.yaml 2>/dev/null | head -1 || echo 'n/a')"
  exit 0
fi

# Update the ConfigMap
log_info "Updating ConfigMap openclaw-config..."
$KUBECTL create configmap openclaw-config \
  --from-literal="openclaw.json=$LIVE_CONFIG" \
  -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -

log_success "ConfigMap updated"
echo ""
log_info "The ConfigMap now matches the live config."
log_info "Next restart will preserve your changes."
echo ""
