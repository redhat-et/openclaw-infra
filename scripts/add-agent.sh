#!/usr/bin/env bash
# ============================================================================
# ADD AGENT (end-to-end)
# ============================================================================
# Scaffolds a new agent from the _template directory AND deploys it to
# the running OpenClaw instance. No manual config editing required.
#
# Usage:
#   ./scripts/add-agent.sh                                    # Interactive
#   ./scripts/add-agent.sh myagent "My Agent" "Description"   # Non-interactive
#   ./scripts/add-agent.sh --scaffold-only myagent ...        # Files only, no deploy
#
# Flags:
#   --k8s              Use kubectl instead of oc
#   --scaffold-only    Create files but don't deploy to cluster
#   --env-file PATH    Custom .env file
#
# This script:
#   1. Copies _template/ to agents/<id>/
#   2. Substitutes placeholders in the copied files
#   3. Optionally creates a JOB.md for scheduled tasks
#   4. Runs envsubst on the agent template
#   5. Applies the agent ConfigMap to the cluster
#   6. Adds the agent to the live gateway config
#   7. Syncs the config back to the ConfigMap (survives restarts)
#   8. Installs workspace files (AGENTS.md, agent.json)
#   9. Restarts the gateway to load the new agent
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents/openclaw/agents"
TEMPLATE_DIR="$AGENTS_DIR/_template"

# Defaults
K8S_MODE=false
SCAFFOLD_ONLY=false
ENV_FILE=""

# Separate flags from positional args
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s) K8S_MODE=true; shift ;;
    --scaffold-only) SCAFFOLD_ONLY=true; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
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
echo "║  Add OpenClaw Agent                                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

if [ ! -d "$TEMPLATE_DIR" ]; then
  log_error "Template directory not found: $TEMPLATE_DIR"
  exit 1
fi

# ---- Parse positional args or prompt ----

AGENT_ID="${POSITIONAL[0]:-}"
DISPLAY_NAME="${POSITIONAL[1]:-}"
DESCRIPTION="${POSITIONAL[2]:-}"

if [ -z "$AGENT_ID" ]; then
  log_info "Agent ID (lowercase, no spaces — used in filenames and K8s names):"
  read -p "  ID: " AGENT_ID
  if [ -z "$AGENT_ID" ]; then
    log_error "Agent ID is required."
    exit 1
  fi
fi

# Normalize: lowercase, replace spaces with hyphens
AGENT_ID=$(echo "$AGENT_ID" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

if [ -d "$AGENTS_DIR/$AGENT_ID" ]; then
  log_error "Agent directory already exists: $AGENTS_DIR/$AGENT_ID"
  exit 1
fi

if [ -z "$DISPLAY_NAME" ]; then
  read -p "  Display name (e.g., 'Security Scanner'): " DISPLAY_NAME
  if [ -z "$DISPLAY_NAME" ]; then
    DISPLAY_NAME="$AGENT_ID"
  fi
fi

if [ -z "$DESCRIPTION" ]; then
  read -p "  Description (what does this agent do?): " DESCRIPTION
  if [ -z "$DESCRIPTION" ]; then
    DESCRIPTION="A custom OpenClaw agent"
  fi
fi

# Optional: emoji and color
read -p "  Emoji (default: 🤖): " EMOJI
EMOJI="${EMOJI:-🤖}"

read -p "  Color hex (default: #6C5CE7): " COLOR
COLOR="${COLOR:-#6C5CE7}"

echo ""

# ---- Step 1: Scaffold from template ----

log_info "Creating agent: $AGENT_ID"
mkdir -p "$AGENTS_DIR/$AGENT_ID"

cp "$TEMPLATE_DIR/agent.yaml.template" "$AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst"

# Substitute placeholders
sed -i.bak \
  -e "s/REPLACE_AGENT_ID/$AGENT_ID/g" \
  -e "s/REPLACE_DISPLAY_NAME/$DISPLAY_NAME/g" \
  -e "s/REPLACE_DESCRIPTION/$DESCRIPTION/g" \
  -e "s/REPLACE_EMOJI/$EMOJI/g" \
  -e "s/REPLACE_COLOR/$COLOR/g" \
  "$AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst"
rm -f "$AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst.bak"

log_success "Scaffolded $AGENTS_DIR/$AGENT_ID/"

# Ask about scheduled job
echo ""
read -p "Does this agent need a scheduled job? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  cp "$TEMPLATE_DIR/JOB.md.template" "$AGENTS_DIR/$AGENT_ID/JOB.md"
  sed -i.bak "s/REPLACE_AGENT_ID/$AGENT_ID/g" "$AGENTS_DIR/$AGENT_ID/JOB.md"
  rm -f "$AGENTS_DIR/$AGENT_ID/JOB.md.bak"
  log_success "Created JOB.md — edit it to set the schedule and instructions"
fi

# ---- Stop here if scaffold-only ----

if $SCAFFOLD_ONLY; then
  AGENT_ID_UNDERSCORE=$(echo "$AGENT_ID" | tr '-' '_')
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  Scaffold Complete (--scaffold-only)                       ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Files created in: $AGENTS_DIR/$AGENT_ID/"
  echo ""
  echo "To deploy, run this script again without --scaffold-only,"
  echo "or deploy manually:"
  echo ""
  echo "  1. Edit the agent instructions in:"
  echo "     $AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst"
  echo ""
  echo "  2. Run envsubst, apply the ConfigMap, and restart."
  echo ""
  exit 0
fi

# ---- Step 2: Load .env and validate ----

echo ""
if [ ! -f "$ENV_FILE" ]; then
  log_error "No .env file found at $ENV_FILE. Run setup.sh first, or use --scaffold-only."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

for var in OPENCLAW_PREFIX OPENCLAW_NAMESPACE; do
  if [ -z "${!var:-}" ]; then
    log_error "$var not set in .env. Run setup.sh first."
    exit 1
  fi
done

# Verify cluster connection
if ! $KUBECTL get namespace "$OPENCLAW_NAMESPACE" &>/dev/null; then
  log_error "Namespace $OPENCLAW_NAMESPACE not found. Is your cluster connected?"
  exit 1
fi

# ---- Step 3: Run envsubst on the new agent template ----

GENERATED_DIR="$REPO_ROOT/generated"
GENERATED_AGENT_DIR="$GENERATED_DIR/agents/openclaw/agents/$AGENT_ID"
mkdir -p "$GENERATED_AGENT_DIR"

# Copy non-template files
for f in "$AGENTS_DIR/$AGENT_ID"/*; do
  case "$f" in
    *.envsubst) ;; # handled below
    *) cp "$f" "$GENERATED_AGENT_DIR/" 2>/dev/null || true ;;
  esac
done

# Set up envsubst vars
export MODEL_ENDPOINT="${MODEL_ENDPOINT:-http://vllm.openclaw-llms.svc.cluster.local/v1}"
export SHADOWMAN_CUSTOM_NAME="${SHADOWMAN_CUSTOM_NAME:-shadowman}"
export SHADOWMAN_DISPLAY_NAME="${SHADOWMAN_DISPLAY_NAME:-Shadowman}"
export DEFAULT_AGENT_MODEL="${DEFAULT_AGENT_MODEL:-nerc/openai/gpt-oss-20b}"

ENVSUBST_VARS='${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE} ${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME} ${DEFAULT_AGENT_MODEL}'

TPL="$AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst"
OUT="$GENERATED_AGENT_DIR/${AGENT_ID}-agent.yaml"
envsubst "$ENVSUBST_VARS" < "$TPL" > "$OUT"
log_success "Generated $(basename "$OUT")"

# ---- Step 4: Apply the agent ConfigMap ----

log_info "Applying agent ConfigMap..."
$KUBECTL apply -f "$OUT"
log_success "ConfigMap ${AGENT_ID}-agent applied"

# ---- Step 5: Add agent to live gateway config ----

AGENT_ID_UNDERSCORE=$(echo "$AGENT_ID" | tr '-' '_')
AGENT_FULL_ID="${OPENCLAW_PREFIX}_${AGENT_ID_UNDERSCORE}"

log_info "Adding $AGENT_FULL_ID to live gateway config..."

# Use node (available in the pod) to safely modify the JSON config
$KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- node -e "
  const fs = require('fs');
  const configPath = '/home/node/.openclaw/openclaw.json';
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

  if (!config.agents) config.agents = {};
  if (!config.agents.list) config.agents.list = [];

  const agentId = '$AGENT_FULL_ID';
  if (config.agents.list.some(a => a.id === agentId)) {
    console.log('Agent already in config — skipping');
    process.exit(0);
  }

  config.agents.list.push({
    id: agentId,
    name: $(printf '%s' "$DISPLAY_NAME" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))"),
    workspace: '~/.openclaw/workspace-' + agentId,
    subagents: { allowAgents: ['*'] }
  });

  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
  console.log('Agent added to config');
"

log_success "Agent added to live config"

# ---- Step 6: Sync live config back to ConfigMap ----

log_info "Syncing config to ConfigMap (so restarts preserve the change)..."
LIVE_CONFIG=$($KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
  cat /home/node/.openclaw/openclaw.json)

$KUBECTL create configmap openclaw-config \
  --from-literal="openclaw.json=$LIVE_CONFIG" \
  -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -

log_success "ConfigMap synced"

# ---- Step 7: Install workspace files ----

log_info "Installing workspace files..."
CM_NAME="${AGENT_ID}-agent"
WORKSPACE_DIR="/home/node/.openclaw/workspace-${AGENT_FULL_ID}"

$KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- mkdir -p "$WORKSPACE_DIR"

for key in AGENTS.md agent.json; do
  VALUE=$($KUBECTL get configmap "$CM_NAME" -n "$OPENCLAW_NAMESPACE" \
    -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null) || true
  if [ -n "$VALUE" ]; then
    echo "$VALUE" | $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
      sh -c "cat > ${WORKSPACE_DIR}/${key}"
  fi
done

log_success "Workspace files installed"

# ---- Step 8: Restart gateway ----

log_info "Restarting OpenClaw to load the new agent..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=120s
log_success "OpenClaw ready"

# ---- Step 9: Update cron jobs (if JOB.md exists) ----

if [ -f "$AGENTS_DIR/$AGENT_ID/JOB.md" ]; then
  echo ""
  log_info "Updating cron jobs..."
  K8S_FLAG=""
  $K8S_MODE && K8S_FLAG="--k8s"
  "$SCRIPT_DIR/update-jobs.sh" $K8S_FLAG
fi

# ---- Done ----

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Agent Deployed!                                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Agent:     $DISPLAY_NAME"
echo "  ID:        $AGENT_FULL_ID"
echo "  Workspace: $WORKSPACE_DIR"
echo ""
echo "  Edit instructions: $AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst"
echo "  After editing, re-run: ./scripts/add-agent.sh  (or redeploy manually)"
echo ""
if [ -f "$AGENTS_DIR/$AGENT_ID/JOB.md" ]; then
  echo "  Scheduled job: edit $AGENTS_DIR/$AGENT_ID/JOB.md"
  echo "  Update jobs:   ./scripts/update-jobs.sh"
  echo ""
fi
echo "  Sync UI changes: ./scripts/sync-config.sh"
echo ""
