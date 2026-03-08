# OpenClaw Deployment

Deploy OpenClaw gateway on OpenShift or vanilla Kubernetes with security hardening, OpenTelemetry observability, and a default interactive agent.

## Deployment

### Using setup.sh (Recommended)

```bash
./scripts/setup.sh           # OpenShift
./scripts/setup.sh --k8s     # Kubernetes
```

See the [main README](../../README.md) for full setup instructions.

### Manual Deployment (OpenShift)

```bash
# 1. Generate secrets and set your namespace prefix
export OPENCLAW_PREFIX="myname"
export OPENCLAW_NAMESPACE="${OPENCLAW_PREFIX}-openclaw"
export OPENCLAW_GATEWAY_TOKEN=$(openssl rand -base64 32)
export OPENCLAW_OAUTH_CLIENT_SECRET=$(openssl rand -base64 32)
export OPENCLAW_OAUTH_COOKIE_SECRET=$(openssl rand -hex 16)
export CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

# Set defaults for agent name (or customize)
export SHADOWMAN_CUSTOM_NAME="shadowman"
export SHADOWMAN_DISPLAY_NAME="Shadowman"

# 2. Build generated/ directory with processed templates
GENERATED_DIR="../../generated"
rm -rf "$GENERATED_DIR"
mkdir -p "$GENERATED_DIR"
rsync -a --exclude='*.envsubst' ../../agents/ "$GENERATED_DIR/agents/"
rsync -a --exclude='*.envsubst' ../../platform/ "$GENERATED_DIR/platform/"

ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET} ${ANTHROPIC_API_KEY} ${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME} ${MODEL_ENDPOINT} ${DEFAULT_AGENT_MODEL} ${GOOGLE_CLOUD_PROJECT} ${GOOGLE_CLOUD_LOCATION}'
for tpl in $(find ../../agents ../../platform -name '*.envsubst'); do
  rel="${tpl#../../}"
  out="$GENERATED_DIR/${rel%.envsubst}"
  mkdir -p "$(dirname "$out")"
  envsubst "$ENVSUBST_VARS" < "$tpl" > "$out"
done

# 3. Create namespace and deploy from generated/
oc create namespace "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
oc apply -f "$GENERATED_DIR/platform/overlays/openshift/oauthclient.yaml"   # Requires cluster-admin
oc apply -k "$GENERATED_DIR/agents/openclaw/overlays/openshift/"

# 4. Verify
oc rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
oc get route openclaw -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.spec.host}'
```

### Manual Deployment (Vanilla Kubernetes)

```bash
# 1. Generate secrets and set your namespace prefix
export OPENCLAW_PREFIX="myname"
export OPENCLAW_NAMESPACE="${OPENCLAW_PREFIX}-openclaw"
export OPENCLAW_GATEWAY_TOKEN=$(openssl rand -base64 32)
export SHADOWMAN_CUSTOM_NAME="shadowman"
export SHADOWMAN_DISPLAY_NAME="Shadowman"

export CLUSTER_DOMAIN="" OPENCLAW_OAUTH_CLIENT_SECRET=""
export OPENCLAW_OAUTH_COOKIE_SECRET=""
export ANTHROPIC_API_KEY=""

# 2. Build generated/ directory (see OpenShift section above for full envsubst setup)
# ... same rsync + envsubst loop as above ...

# 3. Create namespace and deploy from generated/
kubectl create namespace "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k "$GENERATED_DIR/agents/openclaw/overlays/k8s/"

# 4. Access via port-forward
kubectl rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
kubectl port-forward svc/openclaw 18789:18789 -n "$OPENCLAW_NAMESPACE"
# Open http://localhost:18789
```

### What You Get

- OpenClaw gateway with Control UI and WebChat
- One interactive agent (Shadowman, or customized via `SHADOWMAN_CUSTOM_NAME`)
- OpenTelemetry diagnostics plugin enabled
- Security hardening (ResourceQuota, PDB, read-only filesystem, non-root, dropped capabilities)
- OAuth-protected UI (OpenShift) or token-based auth (K8s)

- No cron jobs included in base deploy (add via `setup-agents.sh`)


## Model Options

Agents need an LLM. The setup script asks you to choose one source (Anthropic API key, Vertex AI, or local model), then prompts only for that choice.

| Option | Provider | `DEFAULT_AGENT_MODEL` |
|--------|----------|----------------------|
| Anthropic API key | `anthropic` | `anthropic/claude-sonnet-4-6` |
| Anthropic via Vertex | `anthropic-vertex` | `anthropic-vertex/claude-sonnet-4-6` |
| Google Vertex AI (Gemini) | `google-vertex` | `google-vertex/gemini-2.5-pro` |
| In-cluster vLLM | `local` | `local/openai/gpt-oss-20b` |

**Vertex AI** (option 2 at setup): default provider is **anthropic** (Claude); you can choose **google** (Gemini). Requires a GCP project and service account JSON key with Vertex AI permissions. The setup script creates a `vertex-credentials` K8s secret and sets `GOOGLE_APPLICATION_CREDENTIALS` (to `/vertex/vertex-credentials.json`), `GOOGLE_CLOUD_PROJECT`, and `GOOGLE_CLOUD_LOCATION` on the pod. **Note:** Claude via Vertex (anthropic-vertex) currently hits a 404 in the gateway because the adapter uses `/v1/messages` while Vertex uses a different path; use the Anthropic API key (option 1) for Claude, or Vertex with provider **google** for Gemini.

To deploy the vLLM model server, see [`agents/openclaw/llm/`](./llm/).

## Architecture

```
OpenShift:
  Internet --> Route (TLS) --> OAuth Proxy (8443) --> Gateway (18789) --> Model Provider

Kubernetes:
  localhost:18789 --> Gateway (18789) --> Model Provider
```

## Directory Structure

```
agents/openclaw/
├── README.md                                 # This file
├── SECURITY.md                               # Security guide
├── a2a-bridge/                               # A2A JSON-RPC to OpenAI bridge
│   ├── a2a-bridge.py                         # Bridge script (ConfigMap-mounted)
│   └── kustomization.yaml                    # ConfigMap generator
├── base/                                     # Shared base resources
│   ├── kustomization.yaml
│   ├── openclaw-deployment.yaml              # Gateway + A2A bridge + init container
│   ├── openclaw-service.yaml
│   ├── openclaw-route.yaml                   # OpenShift route
│   ├── openclaw-config-configmap.yaml        # Default config (base)
│   ├── openclaw-secrets-secret.yaml          # Gateway token secret
│   ├── openclaw-oauth-*.yaml                 # OAuth proxy config + SA
│   ├── openclaw-*-pvc-*.yaml                 # Home + workspace PVCs
│   ├── openclaw-networkpolicy.yaml           # Network isolation
│   ├── openclaw-resourcequota.yaml           # 4 CPU, 8Gi RAM limits
│   ├── openclaw-poddisruptionbudget.yaml     # HA config
│   └── shadowman-agent.yaml                  # Default agent ConfigMap
├── base-k8s/                                 # K8s-specific base (no routes/OAuth)
│   ├── kustomization.yaml
│   ├── deployment-k8s-patch.yaml
│   └── service-k8s-patch.yaml
├── overlays/
│   ├── openshift/                            # OpenShift overlay
│   │   ├── kustomization.yaml.envsubst       # Namespace + patches
│   │   ├── config-patch.yaml.envsubst        # Gateway config (models, agents, tools)
│   │   ├── secrets-patch.yaml.envsubst       # Real secrets
│   │   ├── deployment-patch.yaml.envsubst    # OTEL sidecar, Anthropic key
│   │   ├── route-patch.yaml                  # Route host
│   │   └── oauthclient.yaml.envsubst         # Cluster-scoped OAuthClient
│   └── k8s/                                  # Vanilla Kubernetes overlay
│       ├── kustomization.yaml.envsubst
│       ├── config-patch.yaml.envsubst        # Gateway config (no OAuth)
│       └── secrets-patch.yaml.envsubst
├── agents/                                   # Agent configs, RBAC, cron jobs
│   ├── shadowman/                            # Default agent (customizable name)
│   │   └── shadowman-agent.yaml.envsubst
│   ├── resource-optimizer/                   # Resource Optimizer agent
│   │   ├── resource-optimizer-agent.yaml.envsubst
│   │   ├── resource-optimizer-rbac.yaml.envsubst
│   │   └── resource-report-cronjob.yaml.envsubst
│   ├── mlops-monitor/                        # MLOps monitor agent, RBAC, CronJob
│   ├── audit-reporter/                       # Compliance monitoring (future)
│   ├── agents-config-patch.yaml.envsubst     # Agent list config overlay
│   ├── demo-workloads/                       # Demo workloads for resource-optimizer
│   └── remove-custom-agents.sh              # Cleanup script
├── skills/                                  # Agent skills
│   ├── a2a/SKILL.md                         # A2A cross-instance communication
│   ├── nps/SKILL.md                         # NPS Agent query skill
│   └── kustomization.yaml                   # Skill ConfigMap generator
├── llm/                                     # vLLM reference deployment
│   ├── kustomization.yaml
│   ├── namespace.yaml                       # openclaw-llms namespace
│   ├── vllm-deployment.yaml                 # vLLM serving openai/gpt-oss-20b
│   ├── vllm-service.yaml                    # ClusterIP service (port 80)
│   ├── vllm-pvc.yaml                        # 30Gi model cache
│   └── README.md                            # Usage and GPU requirements
```

## Configuration

The base ConfigMap (`base/openclaw-config-configmap.yaml`) provides defaults. The overlay `config-patch.yaml.envsubst` overrides with environment-specific values.

Key config sections in `openclaw.json`:

| Section | Purpose |
|---------|---------|
| `gateway` | Bind address, port, auth mode, trusted proxies, Control UI settings |
| `models.providers` | Model provider URLs and model definitions |
| `tools` | Tool allow/deny lists, exec security (allowlist mode, safe binaries) |
| `agents` | Default workspace, model, and agent list |
| `diagnostics.otel` | OpenTelemetry endpoint, trace/metric/log toggles |
| `cron` | Enable/disable cron job scheduler |

### Security Settings

- **Auth mode**: `token` - requires `OPENCLAW_GATEWAY_TOKEN` for API access
- **Device auth**: Disabled when behind OAuth proxy (OAuth provides stronger auth)
- **Exec security**: `allowlist` mode - only `curl` is permitted by default
- **Tool deny list**: `browser`, `canvas`, `nodes`, `process`, `tts`, `gateway` are blocked

## Security Features

- Non-root containers with dropped capabilities
- Read-only root filesystem
- ResourceQuota: 4 CPU, 8Gi RAM per namespace
- PodDisruptionBudget for high availability
- NetworkPolicy for ingress/egress isolation
- OAuth proxy (OpenShift) or token auth (K8s)
- Command execution allowlist (default: `curl` only)

## Troubleshooting

**Pod logs:**
```bash
oc logs -n <prefix>-openclaw deployment/openclaw --all-containers
```

**Events:**
```bash
oc get events -n <prefix>-openclaw --sort-by='.lastTimestamp'
```

**Config on PVC:**
```bash
oc exec deployment/openclaw -n <prefix>-openclaw -c gateway -- cat /home/node/.openclaw/openclaw.json
```

**Export live config locally:**
```bash
./scripts/export-config.sh
```

See [SECURITY.md](./SECURITY.md) for the full security guide.
