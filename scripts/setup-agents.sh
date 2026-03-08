#!/usr/bin/env bash
# ============================================================================
# AGENT-ONLY SETUP SCRIPT
# ============================================================================
# Deploy (or re-deploy) AI agents to an existing OpenClaw instance.
# Uses the existing .env — does NOT regenerate secrets.
#
# Usage:
#   ./setup-agents.sh                          # OpenShift (default)
#   ./setup-agents.sh --k8s                    # Vanilla Kubernetes
#   ./setup-agents.sh --env-file path/to/.env  # Use a specific .env file
#
# Prerequisites:
#   - setup.sh has been run at least once (so .env and namespace exist)
#   - OpenClaw is deployed and running
#
# This script:
#   - Sources .env for secrets and config (OPENCLAW_PREFIX, OPENCLAW_NAMESPACE, etc.)
#   - Runs envsubst on agent templates only
#   - Deploys agent ConfigMaps (shadowman, resource-optimizer)
#   - Sets up resource-optimizer RBAC and demo workloads
#   - Restarts OpenClaw to load config
#   - Sets up cron jobs for autonomous tasks
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
K8S_MODE=false
ENV_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s) K8S_MODE=true; shift ;;
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

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw Agent Setup                                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load .env
if [ ! -f "$ENV_FILE" ]; then
  log_error "No .env file found. Run setup.sh first."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

# Source .env.a2a for cluster-level A2A config (Keycloak, SPIRE settings)
# Now managed by Kagenti operator — .env.a2a survives .env wipes
if [ -f "$REPO_ROOT/.env.a2a" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env.a2a"
  set +a
fi

# Validate required vars
for var in OPENCLAW_PREFIX OPENCLAW_NAMESPACE; do
  if [ -z "${!var:-}" ]; then
    log_error "$var not set in .env. Run setup.sh first (or add it manually)."
    exit 1
  fi
done

# Prompt for custom default agent name
if [ -n "${SHADOWMAN_CUSTOM_NAME:-}" ]; then
  log_info "Using saved agent name: ${SHADOWMAN_DISPLAY_NAME:-$SHADOWMAN_CUSTOM_NAME}"
else
  echo "Your default agent is 'Shadowman'. Would you like to customize its name?"
  read -p "  Enter a name (or press Enter to keep 'Shadowman'): " CUSTOM_NAME
  if [ -n "$CUSTOM_NAME" ]; then
    SHADOWMAN_DISPLAY_NAME="$CUSTOM_NAME"
    SHADOWMAN_CUSTOM_NAME=$(echo "$CUSTOM_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')
    log_success "Agent will be named '${SHADOWMAN_DISPLAY_NAME}' (id: ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME})"
    # Save to .env for future runs
    if ! grep -q '^SHADOWMAN_CUSTOM_NAME=' "$ENV_FILE" 2>/dev/null; then
      echo "" >> "$ENV_FILE"
      echo "# Custom default agent name (set by setup-agents.sh)" >> "$ENV_FILE"
      echo "SHADOWMAN_CUSTOM_NAME=${SHADOWMAN_CUSTOM_NAME}" >> "$ENV_FILE"
      echo "SHADOWMAN_DISPLAY_NAME=${SHADOWMAN_DISPLAY_NAME}" >> "$ENV_FILE"
    else
      sed -i.bak "s/^SHADOWMAN_CUSTOM_NAME=.*/SHADOWMAN_CUSTOM_NAME=${SHADOWMAN_CUSTOM_NAME}/" "$ENV_FILE"
      sed -i.bak "s/^SHADOWMAN_DISPLAY_NAME=.*/SHADOWMAN_DISPLAY_NAME=${SHADOWMAN_DISPLAY_NAME}/" "$ENV_FILE"
      rm -f "${ENV_FILE}.bak"
    fi
  else
    SHADOWMAN_CUSTOM_NAME="shadowman"
    SHADOWMAN_DISPLAY_NAME="Shadowman"
    log_info "Keeping default name: Shadowman"
  fi
  export SHADOWMAN_CUSTOM_NAME SHADOWMAN_DISPLAY_NAME
fi

log_info "Namespace: $OPENCLAW_NAMESPACE"
log_info "Prefix:    $OPENCLAW_PREFIX"
log_info "Agents:    ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}, ${OPENCLAW_PREFIX}_resource_optimizer, ${OPENCLAW_PREFIX}_mlops_monitor"
echo ""

# Verify cluster connection
if ! $KUBECTL get namespace "$OPENCLAW_NAMESPACE" &>/dev/null; then
  log_error "Namespace $OPENCLAW_NAMESPACE not found. Run setup.sh first."
  exit 1
fi
log_success "Connected to cluster, namespace exists"

# Update namespace annotations with agent roster
AGENT_LIST="${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME},${OPENCLAW_PREFIX}_resource_optimizer,${OPENCLAW_PREFIX}_mlops_monitor"
$KUBECTL annotate namespace "$OPENCLAW_NAMESPACE" \
  "openclaw.dev/agent-name=$SHADOWMAN_DISPLAY_NAME" \
  "openclaw.dev/agent-id=${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}" \
  "openclaw.dev/agents=$AGENT_LIST" \
  --overwrite > /dev/null
log_success "Namespace annotations updated (agents: $AGENT_LIST)"
echo ""

# Generated directory (created by setup.sh, we add to it here)
GENERATED_DIR="$REPO_ROOT/generated"
if [ ! -d "$GENERATED_DIR" ]; then
  log_error "generated/ directory not found. Run setup.sh first."
  exit 1
fi

# Refresh static agent files in generated/
rsync -a --exclude='*.envsubst' "$REPO_ROOT/agents/openclaw/agents/" "$GENERATED_DIR/agents/openclaw/agents/"

# Run envsubst on agent templates only
log_info "Running envsubst on agent templates..."
export MODEL_ENDPOINT="${MODEL_ENDPOINT:-http://vllm.openclaw-llms.svc.cluster.local/v1}"
export VERTEX_ENABLED="${VERTEX_ENABLED:-false}"
export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-}"
export GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-}"

# MLflow defaults (for existing .env files that don't have these yet)
export MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URI:-http://mlflow-service.mlflow.svc.cluster.local:5000}"
export MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-0}"
if [[ "$MLFLOW_TRACKING_URI" =~ ^https:// ]]; then
  export MLFLOW_TLS_INSECURE="false"
else
  export MLFLOW_TLS_INSECURE="true"
fi

# Agent model priority: Anthropic API > Vertex (anthropic or google) > in-cluster
# VERTEX_PROVIDER controls which Vertex provider: "google" (default) or "anthropic"
export VERTEX_PROVIDER="${VERTEX_PROVIDER:-google}"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  export DEFAULT_AGENT_MODEL="anthropic/claude-sonnet-4-6"
elif [ "${VERTEX_ENABLED:-}" = "true" ] && [ "${VERTEX_PROVIDER}" = "anthropic" ]; then
  export DEFAULT_AGENT_MODEL="anthropic-vertex/claude-sonnet-4-6"
  log_info "Using Anthropic Vertex (Claude via GCP) as default agent model"
elif [ "${VERTEX_ENABLED:-}" = "true" ]; then
  export DEFAULT_AGENT_MODEL="google-vertex/gemini-2.5-pro"
  log_info "Using Google Vertex (Gemini) as default agent model"
else
  export DEFAULT_AGENT_MODEL="local/openai/gpt-oss-20b"
  log_info "No Anthropic API key or Vertex — agents will use in-cluster model (${MODEL_ENDPOINT})"
fi

ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET} ${ANTHROPIC_API_KEY} ${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME} ${MODEL_ENDPOINT} ${DEFAULT_AGENT_MODEL} ${GOOGLE_CLOUD_PROJECT} ${GOOGLE_CLOUD_LOCATION} ${KEYCLOAK_URL} ${KEYCLOAK_REALM} ${KEYCLOAK_ADMIN_USERNAME} ${KEYCLOAK_ADMIN_PASSWORD} ${MLFLOW_TRACKING_URI} ${MLFLOW_EXPERIMENT_ID} ${MLFLOW_TLS_INSECURE}'

for tpl in $(find "$REPO_ROOT/agents/openclaw/agents" -name '*.envsubst'); do
  rel="${tpl#$REPO_ROOT/}"
  out="$GENERATED_DIR/${rel%.envsubst}"
  mkdir -p "$(dirname "$out")"
  envsubst "$ENVSUBST_VARS" < "$tpl" > "$out"
  log_success "Generated $(basename "$out")"
done
echo ""

# Deploy agent configuration (overlay config patch)
if ! $K8S_MODE; then
  log_info "Deploying agent configuration..."
  $KUBECTL apply -f "$GENERATED_DIR/agents/openclaw/agents/agents-config-patch.yaml"
  log_success "Agent configuration deployed"
  echo ""
fi

# Assemble agent ConfigMaps from separate files (AGENTS.md, agent.json)
# If an agent dir has separate AGENTS.md + agent.json, embed them into the ConfigMap YAML.
# Agents with monolithic ConfigMaps (e.g. shadowman) are applied as-is.
indent_yaml() { sed 's/^/    /'; }

for agent_dir in "$GENERATED_DIR/agents/openclaw/agents"/*/; do
  [ -d "$agent_dir" ] || continue
  agent_name="$(basename "$agent_dir")"
  cm_yaml="$agent_dir/${agent_name}-agent.yaml"
  agents_md="$agent_dir/AGENTS.md"
  agent_json="$agent_dir/agent.json"

  if [ -f "$cm_yaml" ] && [ -f "$agents_md" ] && [ -f "$agent_json" ]; then
    # Rebuild ConfigMap with embedded file contents
    ns="${OPENCLAW_NAMESPACE}"
    cat > "$cm_yaml" <<CONFIGMAP_EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${agent_name}-agent
  namespace: ${ns}
  labels:
    app: openclaw
    agent: ${agent_name}
data:
  AGENTS.md: |
$(cat "$agents_md" | indent_yaml)
  agent.json: |
$(cat "$agent_json" | indent_yaml)
CONFIGMAP_EOF
  fi
done

# Deploy agent ConfigMaps AFTER config patch (must come after any kustomize apply,
# since the base kustomization includes a default shadowman-agent that would overwrite)
log_info "Deploying agent ConfigMaps..."
AGENT_CM_COUNT=0
for agent_yaml in "$GENERATED_DIR/agents/openclaw/agents"/*/*-agent.yaml; do
  [ -f "$agent_yaml" ] || continue
  $KUBECTL apply -f "$agent_yaml"
  AGENT_CM_COUNT=$((AGENT_CM_COUNT + 1))
  log_success "  $(basename "$(dirname "$agent_yaml")")"
done
log_success "$AGENT_CM_COUNT agent ConfigMaps deployed"
echo ""

# Deploy NPS skill ConfigMap
log_info "Deploying NPS skill..."
$KUBECTL kustomize "$GENERATED_DIR/agents/openclaw/skills" \
  | sed "s/namespace: openclaw/namespace: $OPENCLAW_NAMESPACE/g" \
  | $KUBECTL apply -f -
log_success "NPS skill ConfigMap deployed"
echo ""

# Setup resource-optimizer RBAC (ServiceAccount + read-only access to resource-demo)
log_info "Setting up resource-optimizer RBAC..."
$KUBECTL create namespace resource-demo --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null
$KUBECTL apply -f "$GENERATED_DIR/agents/openclaw/agents/resource-optimizer/resource-optimizer-rbac.yaml"
# Deploy demo workloads for resource-optimizer to analyze
for demo in "$GENERATED_DIR/agents/openclaw/agents/demo-workloads"/demo-*.yaml; do
  [ -f "$demo" ] && $KUBECTL apply -f "$demo"
done
# Pre-create the resource-report-latest ConfigMap (CronJob will update it)
$KUBECTL create configmap resource-report-latest \
  --from-literal=report.txt="No report generated yet. The resource-report CronJob has not run." \
  -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
# Deploy K8s CronJob for resource reports (runs independently of the LLM)
$KUBECTL apply -f "$GENERATED_DIR/agents/openclaw/agents/resource-optimizer/resource-report-cronjob.yaml"
log_success "Resource-optimizer RBAC, demo workloads, report ConfigMap, and CronJob applied"
echo ""

# Setup mlops-monitor RBAC and CronJob
log_info "Setting up mlops-monitor..."
$KUBECTL apply -f "$GENERATED_DIR/agents/openclaw/agents/mlops-monitor/mlops-monitor-rbac.yaml"
# Pre-create the mlops-report-latest ConfigMap (CronJob will update it)
$KUBECTL create configmap mlops-report-latest \
  --from-literal=report.txt="No report generated yet. The mlops-report CronJob has not run." \
  -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
# Create mlops-monitor secrets (MLFLOW_TRACKING_URI — set by setup.sh)
MLFLOW_URI="${MLFLOW_TRACKING_URI:-}"
if [ -z "$MLFLOW_URI" ]; then
  log_info "MLflow tracking URI not set in .env — prompting..."
  log_info "  (Set this in setup.sh to avoid this prompt)"
  read -p "  Enter MLflow URI (or press Enter to skip): " MLFLOW_URI
fi
if [ -n "$MLFLOW_URI" ]; then
  $KUBECTL create secret generic mlops-monitor-secrets \
    --from-literal=MLFLOW_TRACKING_URI="$MLFLOW_URI" \
    -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
  log_success "MLflow tracking URI configured"
else
  # Create empty secret so CronJob doesn't crash
  $KUBECTL create secret generic mlops-monitor-secrets \
    --from-literal=MLFLOW_TRACKING_URI="" \
    -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
  log_warn "No MLflow URI set — mlops-monitor reports will show an error until configured"
fi
# Deploy CronJob
$KUBECTL apply -f "$GENERATED_DIR/agents/openclaw/agents/mlops-monitor/mlops-monitor-cronjob.yaml"
log_success "MLOps-monitor RBAC, report ConfigMap, and CronJob applied"
echo ""

# Restart OpenClaw to pick up new config
log_info "Restarting OpenClaw to load agents..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
log_info "Waiting for OpenClaw to be ready..."
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
log_success "OpenClaw ready"
echo ""

# Install agent workspace files (AGENTS.md, agent.json, SOUL.md, etc.) into each workspace
# Auto-discover: find all deployed agent ConfigMaps and extract their agent ID
log_info "Installing agent workspace files into workspaces..."
for agent_yaml in "$GENERATED_DIR/agents/openclaw/agents"/*/*-agent.yaml; do
  [ -f "$agent_yaml" ] || continue
  AGENT_DIR_NAME="$(basename "$(dirname "$agent_yaml")")"
  CM_NAME="${AGENT_DIR_NAME}-agent"

  # Derive workspace name from agent ID in the ConfigMap
  # For shadowman: uses the custom name; for others: directory name with - → _
  if [ "$AGENT_DIR_NAME" = "shadowman" ]; then
    WORKSPACE="workspace-${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}"
  else
    AGENT_ID_SUFFIX="$(echo "$AGENT_DIR_NAME" | tr '-' '_')"
    WORKSPACE="workspace-${OPENCLAW_PREFIX}_${AGENT_ID_SUFFIX}"
  fi

  WORKSPACE_DIR="/home/node/.openclaw/${WORKSPACE}"

  # Ensure workspace directory exists
  $KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- mkdir -p "$WORKSPACE_DIR"
  for key in AGENTS.md agent.json SOUL.md IDENTITY.md TOOLS.md USER.md HEARTBEAT.md MEMORY.md; do
    # Skip keys that don't exist in this ConfigMap (non-shadowman agents may only have AGENTS.md + agent.json)
    VALUE=$($KUBECTL get configmap "$CM_NAME" -n "$OPENCLAW_NAMESPACE" -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null) || true
    if [ -n "$VALUE" ]; then
      echo "$VALUE" | $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
        sh -c "cat > ${WORKSPACE_DIR}/${key}"
    fi
  done
  log_success "  ${AGENT_DIR_NAME} → ${WORKSPACE}"
done
echo ""

# Install NPS skill into workspace
log_info "Installing NPS skill into workspace..."
$KUBECTL get configmap nps-skill -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.data.SKILL\.md}' | \
  $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
    sh -c 'mkdir -p /home/node/.openclaw/skills/nps && cat > /home/node/.openclaw/skills/nps/SKILL.md'
log_success "NPS skill installed"
echo ""

# Inject resource-optimizer SA token into workspace .env
log_info "Injecting resource-optimizer ServiceAccount token..."
RO_TOKEN=""
for i in $(seq 1 15); do
  RO_TOKEN=$($KUBECTL get secret resource-optimizer-sa-token -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d) || true
  if [ -n "$RO_TOKEN" ]; then break; fi
  log_info "  Waiting for SA token... ($i/15)"
  sleep 2
done

if [ -n "$RO_TOKEN" ]; then
  $KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- sh -c "
    ENV_FILE=\$HOME/.openclaw/workspace-${OPENCLAW_PREFIX}_resource_optimizer/.env
    mkdir -p \$(dirname \$ENV_FILE)
    grep -v '^OC_TOKEN=' \$ENV_FILE > \$ENV_FILE.tmp 2>/dev/null || true
    mv \$ENV_FILE.tmp \$ENV_FILE 2>/dev/null || true
    echo 'OC_TOKEN=$RO_TOKEN' >> \$ENV_FILE
  "
  log_success "Resource-optimizer SA token injected"
else
  log_warn "Could not get SA token — resource-optimizer won't have K8s API access"
  log_warn "Run setup-resource-optimizer-rbac.sh manually after deployment"
fi
echo ""

# Restart gateway to load agent configs and report ConfigMap mount
log_info "Restarting OpenClaw to load agents..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
log_success "OpenClaw ready"
echo ""

# Write OpenClaw internal cron jobs (agent analysis schedule)
"$SCRIPT_DIR/update-jobs.sh" --skip-restart
log_success "Cron jobs written"

# Final restart to load cron jobs
log_info "Final restart to load cron jobs..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
log_success "OpenClaw ready with agents"
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Agent Setup Complete!                                     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Agents deployed:"
for agent_yaml in "$GENERATED_DIR/agents/openclaw/agents"/*/*-agent.yaml; do
  [ -f "$agent_yaml" ] || continue
  dir_name="$(basename "$(dirname "$agent_yaml")")"
  if [ "$dir_name" = "shadowman" ]; then
    echo "  ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME} (${SHADOWMAN_DISPLAY_NAME})"
  else
    agent_id_suffix="$(echo "$dir_name" | tr '-' '_')"
    echo "  ${OPENCLAW_PREFIX}_${agent_id_suffix}"
  fi
done
echo ""
echo "Cron jobs:"
for job_file in "$GENERATED_DIR/agents/openclaw/agents"/*/JOB.md; do
  [ -f "$job_file" ] || continue
  job_id=$(grep '^id:' "$job_file" | head -1 | sed 's/^id: *//')
  schedule=$(grep '^schedule:' "$job_file" | head -1 | sed 's/^schedule: *"*//; s/"*$//')
  echo "  ${job_id}: ${schedule}"
done
echo ""
echo "Add a new agent:  ./scripts/add-agent.sh"
echo "Update jobs:      ./scripts/update-jobs.sh"
echo ""
