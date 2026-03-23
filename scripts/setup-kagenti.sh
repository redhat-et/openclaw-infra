#!/usr/bin/env bash
# ============================================================================
# KAGENTI PLATFORM SETUP
# ============================================================================
# Installs the Kagenti stack (SPIRE, cert-manager, Keycloak, operator, webhook,
# UI, MCP Gateway) on an OpenShift cluster. Run this BEFORE setup.sh --with-a2a.
#
# Usage:
#   ./scripts/setup-kagenti.sh                              # Auto-clones kagenti main to ~/.cache/kagenti
#   ./scripts/setup-kagenti.sh --kagenti-repo /path/to/kagenti  # Use local clone
#   ./scripts/setup-kagenti.sh --kagenti-repo https://github.com/org/kagenti.git  # Clone from URL
#   ./scripts/setup-kagenti.sh --realm nerc                 # Custom Keycloak realm (default: kagenti)
#   ./scripts/setup-kagenti.sh --skip-ovn-patch             # Skip OVN gateway patch
#   ./scripts/setup-kagenti.sh --skip-mcp-gateway           # Skip MCP Gateway install
#
# Prerequisites:
#   - oc / kubectl with cluster-admin
#   - helm >= 3.18.0 (Helm 4 also works)
#   - Local clone of kagenti repo (use sallyom/kagenti branch charts-updated-webhook
#     until port exclusion annotations are merged upstream)
#
# Tested on: OCP 4.19+ (ROSA)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
KAGENTI_REPO="${KAGENTI_REPO:-}"
KAGENTI_CACHE_DIR="${HOME}/.cache/kagenti"
KAGENTI_GITHUB_URL="https://github.com/kagenti/kagenti.git"
KC_REALM="${KEYCLOAK_REALM:-kagenti}"
KC_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
SKIP_OVN_PATCH=false
SKIP_MCP_GATEWAY=false
MCP_GATEWAY_VERSION="0.4.0"
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kagenti-repo)       KAGENTI_REPO="$2"; shift 2 ;;
    --realm)              KC_REALM="$2"; shift 2 ;;
    --keycloak-namespace) KC_NAMESPACE="$2"; shift 2 ;;
    --skip-ovn-patch)     SKIP_OVN_PATCH=true; shift ;;
    --skip-mcp-gateway)   SKIP_MCP_GATEWAY=true; shift ;;
    --mcp-gateway-version) MCP_GATEWAY_VERSION="$2"; shift 2 ;;
    --dry-run)            DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --kagenti-repo PATH|URL   Local path or GitHub URL to kagenti repo (default: clone main to ~/.cache/kagenti)"
      echo "  --realm REALM             Keycloak realm (default: kagenti, or \$KEYCLOAK_REALM)"
      echo "  --keycloak-namespace NS   Keycloak namespace (default: keycloak, or \$KEYCLOAK_NAMESPACE)"
      echo "  --skip-ovn-patch          Skip OVN gateway routing patch"
      echo "  --skip-mcp-gateway        Skip MCP Gateway installation"
      echo "  --mcp-gateway-version VER MCP Gateway chart version (default: $MCP_GATEWAY_VERSION)"
      echo "  --dry-run                 Show commands without executing"
      echo "  -h, --help                Show this help"
      exit 0
      ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

run_cmd() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# ============================================================================
# Pre-flight checks
# ============================================================================
echo ""
echo "============================================"
echo "  Kagenti Platform Setup"
echo "============================================"
echo ""

# Check for kubectl/oc
if command -v oc &>/dev/null; then
  KUBECTL=oc
elif command -v kubectl &>/dev/null; then
  KUBECTL=kubectl
else
  log_error "Neither oc nor kubectl found in PATH"
  exit 1
fi

# Check cluster access
if ! $KUBECTL cluster-info &>/dev/null 2>&1; then
  log_error "Cannot connect to cluster. Run 'oc login' first."
  exit 1
fi
log_success "Connected to cluster"

# Check for stale APIServices that block namespace deletion.
# On some clusters (e.g. with removed kubevirt), stale APIServices cause namespace
# finalizers to hang on API discovery failures. Warn so the user can clean them up.
_stale_apis=$($KUBECTL get apiservices -o json 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
stale = []
for item in data.get('items', []):
    for cond in item.get('status', {}).get('conditions', []):
        if cond.get('type') == 'Available' and cond.get('status') != 'True':
            stale.append(item['metadata']['name'])
print('\n'.join(stale))
" 2>/dev/null || echo "")
if [ -n "$_stale_apis" ]; then
  log_warn "Stale APIServices detected (can cause namespace deletion hangs):"
  echo "$_stale_apis" | while read -r api; do echo "    $api"; done
  log_warn "Consider removing them: oc delete apiservice <name>"
fi

# Check helm
if ! command -v helm &>/dev/null; then
  log_error "helm not found in PATH. Install helm >= 3.18.0"
  exit 1
fi
log_success "helm found: $(helm version --short)"

# Resolve kagenti repo: local path, GitHub URL, or auto-clone from main
_clone_kagenti() {
  local url="$1" dest="$2"
  log_info "Cloning kagenti from ${url} → ${dest}..."
  if $DRY_RUN; then
    echo "  [dry-run] rm -rf \"$dest\""
    echo "  [dry-run] git clone --depth=1 \"$url\" \"$dest\""
    return 0
  fi
  rm -rf "$dest"
  if ! git clone --depth=1 "$url" "$dest" 2>&1; then
    log_error "Failed to clone kagenti from $url"
    exit 1
  fi
  log_success "Cloned kagenti (main)"
}

KAGENTI_SOURCE=""
if [ -z "$KAGENTI_REPO" ]; then
  # No --kagenti-repo given: always clone fresh from upstream main
  KAGENTI_SOURCE="$KAGENTI_GITHUB_URL"
  _clone_kagenti "$KAGENTI_GITHUB_URL" "$KAGENTI_CACHE_DIR"
  KAGENTI_REPO="$KAGENTI_CACHE_DIR"
elif [[ "$KAGENTI_REPO" == http://* ]] || [[ "$KAGENTI_REPO" == https://* ]] || [[ "$KAGENTI_REPO" == git@* ]]; then
  # GitHub/git URL: clone into cache
  KAGENTI_SOURCE="$KAGENTI_REPO"
  _clone_kagenti "$KAGENTI_REPO" "$KAGENTI_CACHE_DIR"
  KAGENTI_REPO="$KAGENTI_CACHE_DIR"
else
  # Local path provided — use as-is
  KAGENTI_SOURCE="$KAGENTI_REPO (local)"
fi

if [ ! -d "$KAGENTI_REPO/charts/kagenti-deps" ] || [ ! -d "$KAGENTI_REPO/charts/kagenti" ]; then
  log_error "Invalid kagenti repo: $KAGENTI_REPO (missing charts/kagenti-deps or charts/kagenti)"
  exit 1
fi
log_success "Kagenti repo: $KAGENTI_SOURCE"
echo ""

# ============================================================================
# Step 1: OVN Gateway Patch
# ============================================================================
log_info "Step 1: OVN Gateway Patch"

if $SKIP_OVN_PATCH; then
  log_info "Skipped (--skip-ovn-patch)"
else
  # Check if this is an OVNKubernetes cluster
  NETWORK_TYPE=$($KUBECTL get network.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.type}' 2>/dev/null || echo "unknown")
  if [ "$NETWORK_TYPE" = "OVNKubernetes" ]; then
    log_info "OVNKubernetes detected — applying routingViaHost patch"
    run_cmd $KUBECTL patch network.operator.openshift.io cluster --type=merge \
      -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
    log_success "OVN gateway patch applied"
  else
    log_info "Network type: $NETWORK_TYPE — skipping OVN patch"
  fi
fi
echo ""

# ============================================================================
# Step 2: Detect Trust Domain
# ============================================================================
log_info "Step 2: Detect trust domain"

DOMAIN="apps.$($KUBECTL get dns cluster -o jsonpath='{ .spec.baseDomain }' 2>/dev/null || echo "")"
if [ "$DOMAIN" = "apps." ] || [ -z "$DOMAIN" ]; then
  log_warn "Could not auto-detect cluster domain"
  read -p "  Enter trust domain (e.g. apps.example.com): " DOMAIN
fi
export DOMAIN
log_success "Trust domain: $DOMAIN"
echo ""

# ============================================================================
# Step 3: Install kagenti-deps (SPIRE + cert-manager)
# ============================================================================
log_info "Step 3: Install kagenti-deps (SPIRE + cert-manager)"

# Pre-flight: ensure enableUserWorkload is set in cluster-monitoring-config.
# The kagenti-deps chart has a kiali-operand hook that tries to REPLACE the entire
# cluster-monitoring-config ConfigMap. On managed clusters this conflicts
# with the endpoint-monitoring-operator which already owns .data.config.yaml.
# We merge enableUserWorkload proactively so the hook failure is non-critical.
_ensure_user_workload_monitoring() {
  if $DRY_RUN; then return; fi
  local existing
  existing=$($KUBECTL get configmap cluster-monitoring-config -n openshift-monitoring \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
  if [ -z "$existing" ]; then
    # ConfigMap doesn't exist or is empty — the hook can create it from scratch
    return
  fi
  if echo "$existing" | grep -q "enableUserWorkload: true"; then
    log_success "User workload monitoring already enabled"
    return
  fi
  # Merge enableUserWorkload into existing config
  local merged
  merged="enableUserWorkload: true"$'\n'"$existing"
  $KUBECTL patch configmap cluster-monitoring-config -n openshift-monitoring \
    --type=merge -p "{\"data\":{\"config.yaml\":$(echo "$merged" | jq -Rs .)}}" >/dev/null
  log_success "Merged enableUserWorkload: true into cluster-monitoring-config"
}
_ensure_user_workload_monitoring

# Install or upgrade kagenti-deps.
# On managed clusters the kiali-operand post-install/post-upgrade hook
# fails because it tries to delete+recreate cluster-monitoring-config, which is owned
# by the endpoint-monitoring-operator. We handle this two ways:
#   - Upgrade: always skip hooks (operands are already running from the initial install)
#   - Fresh install: attempt with hooks; if the hook fails, recover with --no-hooks
#     and manually apply the safe operand CRs
# Wait for a namespace to finish terminating. If it's Active, that's fine — skip it.
# Only intervenes when the namespace is stuck in Terminating state (force-strips finalizers).
_wait_ns_gone() {
  local ns="$1" tries=0
  local phase
  phase=$($KUBECTL get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [ "$phase" != "Terminating" ]; then
    return 0  # Active or doesn't exist — nothing to wait for
  fi
  log_info "  Waiting for $ns to terminate..."
  while $KUBECTL get ns "$ns" &>/dev/null 2>&1; do
    $KUBECTL get ns "$ns" -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; json.dump(d,sys.stdout)" \
      | $KUBECTL replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null 2>&1 || true
    tries=$((tries + 1))
    if [ $tries -ge 30 ]; then log_error "  $ns still exists after 30s"; return 1; fi
    sleep 1
  done
  log_success "  $ns terminated"
}

_helm_kagenti_deps() {
  # Pre-flight: ensure namespaces managed by this chart are not stuck terminating
  # from a previous failed install/uninstall cycle
  for _ns in keycloak istio-cni istio-system istio-ztunnel; do
    _wait_ns_gone "$_ns"
  done

  if helm status kagenti-deps -n kagenti-system &>/dev/null 2>&1; then
    # Upgrade path: skip hooks (operands already exist, and the kiali hook will fail
    # on any cluster where cluster-monitoring-config is managed by another operator)
    log_info "kagenti-deps already installed — upgrading (hooks skipped)"
    run_cmd helm upgrade kagenti-deps "$KAGENTI_REPO/charts/kagenti-deps/" \
      -n kagenti-system \
      --set spire.trustDomain="${DOMAIN}" --no-hooks --wait
    return $?
  fi

  # Fresh install: try with hooks first (needed for SPIRE, Istio, Keycloak operand CRs)
  log_info "Installing kagenti-deps..."
  run_cmd helm dependency update "$KAGENTI_REPO/charts/kagenti-deps/"
  if run_cmd helm install kagenti-deps "$KAGENTI_REPO/charts/kagenti-deps/" \
    -n kagenti-system --create-namespace \
    --set spire.trustDomain="${DOMAIN}" --wait 2>&1; then
    return 0
  fi

  # Check if the failure was the known cluster-monitoring-config conflict
  local desc
  desc=$(helm status kagenti-deps -n kagenti-system -o json 2>/dev/null | jq -r '.info.description // empty')
  if ! echo "$desc" | grep -q "cluster-monitoring-config"; then
    log_error "kagenti-deps install failed (not the known monitoring-config issue)"
    return 1
  fi

  log_warn "Hook failed on cluster-monitoring-config (managed by another operator)"
  log_info "Recovering: re-installing without hooks..."

  # Uninstall the failed release and wait for namespaces to clear
  helm uninstall kagenti-deps -n kagenti-system --no-hooks 2>/dev/null || true
  for _ns in keycloak istio-cni istio-system istio-ztunnel; do
    _wait_ns_gone "$_ns"
  done

  # Reinstall without hooks
  run_cmd helm install kagenti-deps "$KAGENTI_REPO/charts/kagenti-deps/" \
    -n kagenti-system --create-namespace \
    --set spire.trustDomain="${DOMAIN}" --no-hooks --wait

  # Re-apply operand CRs that --no-hooks skipped (excluding the conflicting ConfigMap).
  log_info "Applying operand CRs skipped by --no-hooks..."
  helm get hooks kagenti-deps -n kagenti-system 2>/dev/null | python3 -c "
import sys
content = sys.stdin.read()
docs = content.split('---')
for doc in docs:
    if not doc.strip():
        continue
    # Skip pre-install hooks (CRD waiter SA, Role, RoleBinding)
    if 'pre-install' in doc and 'post-install' not in doc:
        continue
    # Skip the cluster-monitoring-config ConfigMap (the conflict source)
    if 'kind: ConfigMap' in doc and 'cluster-monitoring-config' in doc:
        continue
    # Skip the CRD waiter Job
    if 'kind: Job' in doc:
        continue
    lines = [l for l in doc.strip().split('\n')
             if 'helm.sh/hook' not in l and 'helm.sh/hook-weight' not in l and 'helm.sh/hook-delete-policy' not in l]
    print('---')
    print('\n'.join(lines))
" | $KUBECTL apply -f - 2>/dev/null || true
  log_success "kagenti-deps recovered (operand CRs applied)"
}
_helm_kagenti_deps
log_success "kagenti-deps installed"
echo ""

# ============================================================================
# Step 4: Install MCP Gateway
# ============================================================================
log_info "Step 4: Install MCP Gateway"

if $SKIP_MCP_GATEWAY; then
  log_info "Skipped (--skip-mcp-gateway)"
elif helm status mcp-gateway -n mcp-system &>/dev/null 2>&1; then
  log_info "MCP Gateway already installed — skipping"
else
  log_info "Installing MCP Gateway v${MCP_GATEWAY_VERSION}..."
  run_cmd helm install mcp-gateway oci://ghcr.io/kagenti/charts/mcp-gateway \
    --create-namespace --namespace mcp-system --version "$MCP_GATEWAY_VERSION"
  log_success "MCP Gateway installed"
fi
echo ""

# ============================================================================
# Step 5: Install Kagenti (Keycloak + operator + webhook + UI)
# ============================================================================
log_info "Step 5: Install Kagenti (Keycloak + operator + webhook + UI)"

# Secrets file
SECRETS_FILE="$KAGENTI_REPO/charts/kagenti/.secrets.yaml"
SECRETS_TEMPLATE="$KAGENTI_REPO/charts/kagenti/.secrets_template.yaml"
if [ ! -f "$SECRETS_FILE" ]; then
  if [ -f "$SECRETS_TEMPLATE" ]; then
    log_info "Creating .secrets.yaml from template"
    cp "$SECRETS_TEMPLATE" "$SECRETS_FILE"
    log_warn "Edit $SECRETS_FILE if you need custom secrets (e.g. Keycloak admin password)"
  else
    log_error "No .secrets_template.yaml found at $SECRETS_TEMPLATE"
    exit 1
  fi
fi

# Get latest tag
log_info "Detecting latest kagenti release tag..."
LATEST_TAG=$(git ls-remote --tags --sort="v:refname" https://github.com/kagenti/kagenti.git | tail -n1 | sed 's|.*refs/tags/v||; s/\^{}//')
if [ -z "$LATEST_TAG" ]; then
  log_warn "Could not detect latest tag — using 'latest'"
  LATEST_TAG="latest"
fi
log_success "Using tag: v${LATEST_TAG}"

run_cmd helm dependency update "$KAGENTI_REPO/charts/kagenti/"

# Detect Keycloak public URL from route (for OIDC redirects in the browser).
# The internal URL (keycloak-service.KC_NAMESPACE:8080) is NOT reachable from outside the cluster.
KC_ROUTE=$($KUBECTL get route keycloak -n "$KC_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$KC_ROUTE" ]; then
  KEYCLOAK_PUBLIC_URL="https://${KC_ROUTE}"
  log_success "Keycloak public URL: $KEYCLOAK_PUBLIC_URL"
else
  # Fallback: construct from cluster domain
  KEYCLOAK_PUBLIC_URL="https://keycloak-${KC_NAMESPACE}.${DOMAIN}"
  log_warn "Keycloak route not found — using constructed URL: $KEYCLOAK_PUBLIC_URL"
fi

log_info "Keycloak: realm=$KC_REALM namespace=$KC_NAMESPACE"

run_cmd helm upgrade --install kagenti "$KAGENTI_REPO/charts/kagenti/" \
  -n kagenti-system --create-namespace \
  -f "$SECRETS_FILE" \
  --set ui.frontend.tag="v${LATEST_TAG}" \
  --set ui.backend.tag="v${LATEST_TAG}" \
  --set "agentOAuthSecret.spiffePrefix=spiffe://${DOMAIN}/sa" \
  --set uiOAuthSecret.useServiceAccountCA=false \
  --set agentOAuthSecret.useServiceAccountCA=false \
  --set "keycloak.publicUrl=${KEYCLOAK_PUBLIC_URL}" \
  --set "keycloak.realm=${KC_REALM}" \
  --set-json 'agentNamespaces=[]'

log_success "Kagenti installed"
echo ""

# ============================================================================
# Step 6: Verify
# ============================================================================
log_info "Step 6: Verify installation"
echo ""

log_info "SPIRE:"
$KUBECTL get daemonsets -n zero-trust-workload-identity-manager 2>/dev/null || log_warn "SPIRE daemonsets not found"
echo ""

log_info "Kagenti pods:"
$KUBECTL get pods -n kagenti-system 2>/dev/null || log_warn "No pods in kagenti-system"
echo ""

log_info "Keycloak pods:"
$KUBECTL get pods -n "$KC_NAMESPACE" 2>/dev/null || log_warn "No pods in $KC_NAMESPACE"
echo ""

# Kagenti UI URL
UI_HOST=$($KUBECTL get route kagenti-ui -n kagenti-system -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || echo "")
if [ -n "$UI_HOST" ]; then
  log_success "Kagenti UI: https://$UI_HOST"
fi

# Keycloak admin credentials (master realm — for admin console only)
KC_SECRET=$($KUBECTL get secret keycloak-initial-admin -n "$KC_NAMESPACE" -o go-template='Username: {{.data.username | base64decode}}  Password: {{.data.password | base64decode}}' 2>/dev/null || echo "")
if [ -n "$KC_SECRET" ]; then
  log_success "Keycloak admin (master realm): $KC_SECRET"
fi

echo ""
echo "============================================"
echo "  Kagenti platform is ready!"
echo ""
echo "  Namespace registration:"
echo "    Namespaces self-register for webhook injection via label:"
echo "      kubectl label namespace <ns> kagenti-enabled=true"
echo "    setup.sh --with-a2a does this automatically."
echo ""
echo "  Next: deploy OpenClaw with A2A:"
echo "    cd $REPO_ROOT"
echo "    ./scripts/setup.sh --with-a2a"
echo "============================================"
echo ""
