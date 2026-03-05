# CLAUDE.md - Guide for AI Assistants

> **Context and instructions for AI assistants working with this repository.**

## What This Repo Is

A reproducible demo of **AI agents running across hybrid platforms** — OpenShift, vanilla Kubernetes, and bare-metal Linux — connected via zero-trust [Google A2A](https://github.com/google/A2A) protocol powered by [Kagenti](https://github.com/kagenti/kagenti) (SPIFFE/SPIRE + Keycloak).

[OpenClaw](https://github.com/openclaw) is used as the agent runtime, but the network architecture (A2A, identity, observability) is designed to stand on its own and work with any agent framework.

### Deployment Targets

| Platform | Setup | What It Does |
|----------|-------|-------------|
| **OpenShift** | `./scripts/setup.sh` | Central gateway with agents, OAuth, routes, OTEL sidecar |
| **Kubernetes** | `./scripts/setup.sh --k8s` | Same as OpenShift minus OAuth/routes (KinD, minikube, etc.) |
| **Edge (RHEL/Fedora)** | `edge/scripts/setup-edge.sh` | Rootless Podman Quadlet, systemd --user, SELinux enforcing |

### The Network Vision

```
                    ┌──── OpenShift Cluster ────┐
                    │  Central Gateway          │
                    │  ├── Supervisor agents     │
                    │  ├── MLflow (traces)       │
                    │  ├── SPIRE Server          │
                    │  └── Keycloak              │
                    └────────┬──────────────────┘
                             │
                    A2A (SPIFFE mTLS, zero-trust)
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
    ┌─────┴─────┐    ┌──────┴─────┐    ┌───────┴────┐
    │ RHEL NUC  │    │ RHEL VM    │    │ K8s cluster │
    │ Quadlet   │    │ Quadlet    │    │ namespace   │
    │ agent     │    │ agent      │    │ agent       │
    └───────────┘    └────────────┘    └────────────┘
```

**Phased rollout:**
- Phase 1 (current): Edge agents with SSH-based lifecycle control from central gateway
- Phase 2: Multi-machine fleet coordination via supervisor agents
- Phase 3: Full zero-trust A2A via Kagenti SPIRE/SPIFFE across all platforms

## Getting Started

### OpenShift / Kubernetes

```bash
./scripts/setup.sh                    # OpenShift (interactive)
./scripts/setup.sh --k8s              # Vanilla Kubernetes
./scripts/setup.sh --preserve-config  # Re-deploy without overwriting live config
```

`setup.sh` prompts for namespace prefix, agent name, API keys, and optional Vertex AI / A2A config. It generates secrets into `.env` (git-ignored), builds a `generated/` directory with processed templates, and deploys via kustomize. On re-runs, it detects config drift (agents added via `add-agent.sh`, UI changes synced via `sync-config.sh`) and prompts to preserve the live config. Use `--preserve-config` to skip the prompt.

### Edge (RHEL / Fedora)

```bash
cd agents/openclaw/edge
./scripts/setup-edge.sh               # Interactive setup on the Linux machine
```

Installs `.kube` Quadlet files with Pod YAML, ConfigMaps, and a credentials ConfigMap into `~/.config/containers/systemd/`. Agent stays stopped until explicitly started (central supervisor controls lifecycle via SSH).

### Local Testing with KinD

```bash
./scripts/create-cluster.sh           # Creates a KinD cluster
./scripts/setup.sh --k8s              # Deploy OpenClaw to it
kubectl port-forward svc/openclaw 18789:18789 -n <prefix>-openclaw
```

### Additional Agents

```bash
./scripts/setup-agents.sh             # OpenShift
./scripts/setup-agents.sh --k8s       # Kubernetes
```

### Other Scripts

| Script | Purpose |
|--------|---------|
| `./scripts/export-config.sh` | Export live `openclaw.json` from running pod |
| `./scripts/sync-config.sh` | Sync live config from pod back to ConfigMap (preserves UI changes across restarts) |
| `./scripts/add-agent.sh` | Scaffold and deploy a new agent end-to-end |
| `./scripts/update-jobs.sh` | Update cron jobs without full re-deploy |
| `./scripts/deploy-otelcollector.sh` | Deploy OTEL sidecar collector for MLflow trace export |
| `./scripts/teardown.sh` | Remove namespace, resources, PVCs |
| `./scripts/setup-nps-agent.sh` | Deploy NPS Agent (separate namespace) |
| `./scripts/build-and-push.sh` | Build images with podman (optional) |
| `./scripts/cleanup-legacy-generated.sh` | Remove old in-place generated files (one-time) |

All scripts accept `--k8s` for vanilla Kubernetes and `--env-file <path>` for custom .env files.

## Repository Structure

The repo is organized into two top-level concerns: **platform** (generic trusted A2A network infrastructure) and **agents** (pluggable agent implementations). OpenClaw is the reference agent implementation.

```
openclaw-k8s/
├── platform/                           # Generic trusted A2A network platform
│   ├── base/                           # Namespace scaffolding, RBAC, quotas, PVCs, PDB
│   ├── auth-identity-bridge/           # AgentCard CR + SCC (Kagenti webhook handles sidecars)
│   ├── observability/                  # OTEL sidecar configs, tracing (Jaeger, collector)
│   ├── overlays/
│   │   ├── openshift/                  # OAuth proxy, Route, SCC RBAC, OAuthClient
│   │   └── k8s/                        # fsGroup patches, service patches (strip OAuth port)
│   └── edge/                           # Generic Quadlet scaffolding: OTEL collector
│
├── agents/
│   ├── openclaw/                       # OpenClaw reference implementation
│   │   ├── base/                       # Deployment, Service, ConfigMap, Secrets, Route
│   │   ├── a2a-bridge/                 # A2A JSON-RPC to OpenAI bridge (ConfigMap-mounted script)
│   │   ├── overlays/
│   │   │   ├── openshift/              # Config, secrets, deployment patches (oauth-proxy)
│   │   │   └── k8s/                    # Config, secrets, deployment patches (fsGroup)
│   │   ├── agents/                     # Agent configs, RBAC, cron jobs
│   │   ├── skills/                     # Agent skills (A2A, NPS)
│   │   ├── edge/                       # OpenClaw Quadlet files, config templates, setup-edge.sh
│   │   └── llm/                        # vLLM reference deployment (GPU model server)
│   ├── nps-agent/                      # NPS Agent (separate namespace, own identity)
│   └── _template/                      # Skeleton for new agent implementations
│
├── generated/                          # Mirror of agents/ + platform/ with envsubst output (GIT-IGNORED)
├── scripts/                            # Deployment and management scripts
├── docs/                               # Architecture and reference docs
└── .env                                # Generated secrets (GIT-IGNORED)
```

### Composition Model

Agent implementations compose with the platform via kustomize `resources`:

```yaml
# agents/openclaw/base/kustomization.yaml
resources:
  - ../../../platform/base                    # Platform base (namespace, PVCs, quotas, PDB)
  - ../../../platform/auth-identity-bridge    # AgentCard + SCC (Kagenti AIB)
  - openclaw-deployment.yaml                  # OpenClaw-specific resources
  - openclaw-service.yaml
  ...

# agents/openclaw/overlays/openshift/kustomization.yaml
# Note: cluster-scoped resources (OAuthClient, SCC-RBAC) applied separately by setup.sh
resources:
  - ../../base                                # OpenClaw agent base (includes platform/base)
patches:
  - path: config-patch.yaml                   # Agent-specific patches
  - path: secrets-patch.yaml
  - path: deployment-patch.yaml
```

To add a new agent, copy `agents/_template/` and customize.

## Key Design Decisions

### envsubst Template System

- `.envsubst` files contain `${VAR}` placeholders and are committed to Git
- `.env` contains real secrets and is git-ignored
- Setup scripts run `envsubst` with explicit variable lists to protect non-env placeholders like `{agentId}`
- All output goes into `generated/` (git-ignored) — a mirror of the source tree with templates processed
- Scripts reference `$GENERATED_DIR/...` for kustomize and kubectl apply

### Config Lifecycle (K8s and Edge)

```
.envsubst template    -->    generated/     -->    ConfigMap    -->    PVC (live config)
(source of truth)          (envsubst output)     (K8s object)       /home/node/.openclaw/openclaw.json
                           setup.sh builds                          init container copies
                           this directory                           on EVERY start
```

- The init container copies `openclaw.json`, `AGENTS.md`, and `agent.json` from ConfigMap mounts into the PVC on every start
- UI changes write to PVC only — they are lost on next restart unless synced
- Use `./scripts/sync-config.sh` to persist live config back to the ConfigMap (survives restarts)
- Use `./scripts/export-config.sh` to save a local copy for reference or diffing

### Per-User Namespaces (K8s)

Each user gets `<prefix>-openclaw`. The `${OPENCLAW_PREFIX}` variable is used throughout templates. Agent IDs follow the pattern `<prefix>_<agent_name>`.

### Edge Security Posture

- Rootless Podman (no root anywhere)
- SELinux: Enforcing
- Tool exec allowlist — agents can only run read-only system commands
- API keys automatically sanitized from child processes
- Loopback-only gateway (default)
- `Restart=no` — agent can't self-activate, only central supervisor via SSH

### K8s vs OpenShift

The agent `base/` composes with `platform/base` and `platform/auth-identity-bridge`. Overlays strip what's not needed:
- `platform/overlays/k8s/` strips OpenShift-specific resources (Route, OAuthClient, SCC, oauth-proxy)
- `agents/openclaw/overlays/k8s/deployment-k8s-patch.yaml` sets `fsGroup: 1000` and `runAsUser/runAsGroup: 1000` on init-config
- `--with-a2a` sets `kagenti.io/inject: enabled` on the pod template; without it, the label is patched to `disabled`

### Agent Registration Ordering

In `setup-agents.sh`, ConfigMaps are applied AFTER the kustomize config patch. The base kustomization includes a default `shadowman-agent` ConfigMap that would overwrite custom agent ConfigMaps if applied later.

## A2A (Zero-Trust Agent Communication)

Cross-namespace and cross-platform agent communication using [Google A2A](https://github.com/google/A2A) protocol with [Kagenti](https://github.com/kagenti/kagenti) for zero-trust identity. **Requires Kagenti platform (SPIRE + Keycloak) on the cluster** — see `docs/KAGENTI-SETUP.md`.

```bash
./scripts/setup.sh --with-a2a              # OpenShift
./scripts/setup.sh --k8s --with-a2a        # Kubernetes
```

When A2A is enabled:
- Deployment gets `kagenti.io/inject: enabled` label on pod template
- Kagenti webhook automatically injects AIB sidecars (proxy-init, spiffe-helper, client-registration, envoy-proxy) at admission time
- Custom SCC applied (OpenShift) for webhook-injected sidecars (NET_ADMIN, NET_RAW)
- A2A skill installed into agent workspaces
- No manual Keycloak configuration needed — Kagenti manages realm and client registration

When A2A is disabled (default):
- `kagenti.io/inject` label is patched to `disabled`, webhook skips injection
- Default deployment has 3 containers: gateway + agent-card (A2A bridge) + init-config (OpenShift adds oauth-proxy)

## Observability

All platforms emit OTLP traces to MLflow:
- **OpenShift/K8s**: OTEL sidecar collector forwards to central MLflow
- **Edge**: Local OTEL collector Quadlet forwards to MLflow route on OpenShift

## Pre-Built Agents

| Agent | ID Pattern | Description | Schedule |
|-------|-----------|-------------|----------|
| Default | `<prefix>_<custom_name>` | Interactive agent (customizable name) | On-demand |
| Resource Optimizer | `<prefix>_resource_optimizer` | K8s resource analysis | Every 8 hours |
| MLOps Monitor | `<prefix>_mlops_monitor` | NPS Agent monitoring via MLflow | Every 6 hours |

## Environment Variables (.env)

| Variable | Source | Purpose |
|----------|--------|---------|
| `OPENCLAW_PREFIX` | User prompt | Namespace name, agent ID prefix |
| `OPENCLAW_NAMESPACE` | Derived: `<prefix>-openclaw` | All K8s resources |
| `OPENCLAW_GATEWAY_TOKEN` | Auto-generated | Gateway auth |
| `CLUSTER_DOMAIN` | Auto-detected (OpenShift) or empty | Routes, OAuth redirects |
| `ANTHROPIC_API_KEY` | User prompt (optional) | Agents using Claude |
| `MODEL_ENDPOINT` | User prompt or default | In-cluster model provider URL |
| `VERTEX_ENABLED` | User prompt (default: `false`) | Google Vertex AI |
| `VERTEX_PROVIDER` | User prompt (default: `google`) | `google` for Gemini, `anthropic` for Claude via Vertex |
| `GOOGLE_CLOUD_PROJECT` | User prompt (if Vertex) | GCP project ID |
| `A2A_ENABLED` | `--with-a2a` flag (default: `false`) | A2A communication |
| `SHADOWMAN_CUSTOM_NAME` | User prompt in setup.sh (or setup-agents.sh) | Default agent ID |
| `SHADOWMAN_DISPLAY_NAME` | User prompt in setup.sh (or setup-agents.sh) | Default agent display name |
| `DEFAULT_AGENT_MODEL` | Derived from API key availability | Model ID for agents |

## Critical Files

| File | Purpose |
|------|---------|
| `agents/openclaw/overlays/openshift/config-patch.yaml.envsubst` | Main gateway config (models, agents, tools) |
| `agents/openclaw/overlays/k8s/config-patch.yaml.envsubst` | K8s gateway config |
| `agents/openclaw/agents/agents-config-patch.yaml.envsubst` | Agent list overlay |
| `agents/openclaw/base/openclaw-deployment.yaml` | Gateway deployment with A2A bridge + init container |
| `agents/openclaw/a2a-bridge/a2a-bridge.py` | A2A JSON-RPC to OpenAI bridge (serves agent card + translates messages) |
| `agents/openclaw/overlays/k8s/deployment-k8s-patch.yaml` | K8s deployment patch |
| `platform/base/kustomization.yaml` | Platform base (namespace, PVCs, quotas, RBAC) |
| `platform/auth-identity-bridge/kustomization.yaml` | AgentCard CR + SCC (Kagenti AIB) |
| `agents/openclaw/edge/openclaw-agent.kube` | Edge agent Quadlet unit |
| `agents/openclaw/edge/openclaw-agent-pod.yaml.envsubst` | Edge Pod YAML template |
| `agents/openclaw/edge/scripts/setup-edge.sh` | Edge deployment script |
| `agents/_template/` | Skeleton for new agent implementations |
| `scripts/setup.sh` | Main K8s/OpenShift deployment script |
| `scripts/setup-agents.sh` | Agent deployment script |
| `docs/FLEET.md` | Fleet management architecture |
| `docs/A2A-ARCHITECTURE.md` | Zero-trust A2A architecture |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| EACCES on `/home/node/.openclaw/canvas` | PVC owned by wrong UID | Delete PVC, redeploy (K8s patch sets fsGroup: 1000) |
| Config changes lost after restart | Init container overwrites from ConfigMap | Run `sync-config.sh` to persist, or `export-config.sh` to save locally |
| OAuthClient 500 "unauthorized_client" | `oc apply` corrupted secret state | Delete and recreate OAuthClient |
| Agent shows wrong name | Init overwrote workspace or browser cache | Re-run `setup-agents.sh`; clear localStorage |
| Kustomize overwrites agent ConfigMap | Base includes default shadowman-agent | `setup-agents.sh` applies ConfigMaps after kustomize |
| Edge agent won't start (Secret error) | podman doesn't support Secret in `--configmap` | Use ConfigMap kind (setup-edge.sh handles this) |
