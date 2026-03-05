# Deploy OpenClaw on OpenShift in 5 Minutes

OpenClaw is an open-source AI agent gateway — a platform for running, managing, and observing AI agents.
This guide gets you from zero to a running OpenClaw instance on OpenShift, with OpenShift OAuth protecting the
UI and enterprise security hardening out of the box.

## Why OpenShift?

OpenClaw runs on any Kubernetes cluster, but OpenShift adds layers of security that matter when you're
running AI agents that can call tools, execute code, and interact with external services.

### What OpenShift gives you for free

**OAuth integration** — OpenClaw's deployment includes an [oauth-proxy](https://github.com/openshift/oauth-proxy)
sidecar that authenticates users against OpenShift's built-in OAuth server. No external identity provider to configure.
If you can `oc login`, you can access your agent.

**Security Context Constraints (SCCs)** — OpenShift's default `restricted-v2` SCC enforces a strict posture on every container:

- Runs as a random, non-root UID assigned by the namespace
- Read-only root filesystem
- All Linux capabilities dropped
- No privilege escalation

The OpenClaw gateway runs happily under `restricted-v2` with no custom SCC required. Every container in the pod — gateway,
oauth-proxy, and init-config — runs unprivileged with `allowPrivilegeEscalation: false`
and `capabilities.drop: [ALL]`.

**Routes with TLS** — OpenShift Routes provide automatic TLS termination via the cluster's wildcard certificate. The gateway listens on loopback only (`127.0.0.1:18789`) — all external traffic goes through the oauth-proxy, which handles authentication before forwarding to the gateway.

### The pod architecture

```
                     ┌─── OpenShift Route (TLS) ───┐
                     │                             │
                     ▼                             │
              ┌─────────────┐                      │
              │ oauth-proxy │ ◄── OpenShift OAuth  │
              │  (port 8443)│                      │
              └──────┬──────┘                      │
                     │ authenticated               │
                     ▼                             │
              ┌─────────────┐                      │
              │   gateway   │ ◄── loopback only    │
              │ (port 18789)│     read-only root   │
              └─────────────┘     all caps dropped │
              ┌─────────────┐                      │
              │ init-config │ ◄── runs at start    │
              │ (init cont) │   copies config→PVC  │
              └─────────────┘                      │
                                                   │
    PVC (/home/node/.openclaw) ◄───────────────────┘
      Config, sessions, agent workspaces
```

All containers run under `restricted-v2`. No custom SCC. No cluster-admin for the workload itself.

### What the platform deploys

Beyond the pod, the setup script creates namespace-level security resources:

| Resource | Purpose |
|----------|---------|
| **ResourceQuota** | Caps the namespace at 4 CPU / 8Gi RAM requests, 20 pods, 100Gi storage |
| **PodDisruptionBudget** | `maxUnavailable: 0` — protects the pod during node maintenance |
| **ServiceAccount** | Dedicated SA for the oauth-proxy (no API permissions granted) |
| **OAuthClient** | Cluster-scoped — registers the instance with OpenShift's OAuth server |

The gateway container has zero Kubernetes API permissions. It talks to model
providers (Anthropic, OpenAI, Vertex AI, etc.) over HTTPS and serves the UI on loopback. That's it.

## Prerequisites

- An OpenShift cluster (4.x) where you can create a namespace
- `oc` CLI authenticated (`oc login`)
- An API key for at least one model provider (Anthropic, OpenAI, Google, etc.)

The OAuthClient is a cluster-scoped resource. If you don't have cluster-admin, the script will print the
exact command to give your admin — it's a single `oc apply`.

## Deploy

```bash
git clone https://github.com/redhat-et/openclaw-k8s.git
cd openclaw-k8s
./scripts/setup.sh
```

The script is interactive. It will prompt you for:

1. **Namespace prefix** — your name or team (e.g., `alice`). Creates the namespace `alice-openclaw`.
2. **Agent name** — a display name for your default agent (e.g., `Atlas`, `Scout`, `Raven`).
3. **API key** — for your model provider. The script detects `ANTHROPIC_API_KEY` from your environment automatically, or
prompts for it.

Everything else is auto-generated (gateway token, OAuth secrets, cookie secrets) and saved to `.env` (git-ignored).

The script builds a `generated/` directory with processed templates, deploys via kustomize, waits for the pod to be
ready, and installs agent workspace files. Total time: about 2 minutes, most of it waiting for the image pull.

## Access your instance

The Route URL is printed at the end of setup:

```
Access URLs:
  OpenClaw Gateway:   https://openclaw-alice-openclaw.apps.your-cluster.example.com
```

OpenShift OAuth handles authentication — you'll be redirected to the OpenShift login page. After authenticating, the
Control UI asks for your **Gateway Token**:

```bash
grep OPENCLAW_GATEWAY_TOKEN .env
```

Paste it in, and you're in.

## What you get

A running OpenClaw gateway with:

- **Your named agent** — an interactive AI agent backed by the model provider you configured
- **WebChat UI** — browser-based chat interface
- **Control UI** — agent management, session history, configuration
### Talk to your agent

Open the WebChat UI from the Control UI sidebar, select your agent, and start chatting. The agent has access to the
tools configured in your gateway — by default, a general-purpose assistant backed by your chosen model.

### Create your own agent

Scaffold and deploy a new agent end-to-end:

```bash
./scripts/add-agent.sh
```

## Model options

The setup script supports multiple model providers. You can also change models after deployment by editing the config.

| Provider | Model | How to configure |
|----------|-------|-----------------|
| Anthropic | `anthropic/claude-sonnet-4-6` | `ANTHROPIC_API_KEY` env var or interactive prompt |
| OpenAI | `openai/gpt-4o` | Interactive prompt during setup |
| Google Vertex AI | `google-vertex/gemini-2.5-pro` | `--vertex` flag, requires GCP project |
| Claude via Vertex | `anthropic-vertex/claude-sonnet-4-6` | `--vertex --vertex-provider anthropic` |
| In-cluster vLLM | Any model on your GPU node | Set `MODEL_ENDPOINT` to your vLLM `/v1` URL |

## Teardown

```bash
./scripts/teardown.sh
```

Removes the namespace, all resources, the OAuthClient, and the `generated/` directory. Your `.env` is kept
unless you pass `--delete-env`.

## Next steps

| What | How |
|------|-----|
| Create a custom agent | `./scripts/add-agent.sh` (scaffolds, deploys, and restarts — end to end) |
| Preserve UI changes | `./scripts/sync-config.sh` (syncs live config back to ConfigMap) |
| Re-deploy safely | `./scripts/setup.sh` detects config drift and prompts to preserve |
| Add scheduled jobs | Create a `JOB.md` in your agent directory, run `./scripts/update-jobs.sh` |
| Enable observability | `./scripts/deploy-otelcollector.sh` (requires OTEL Operator + MLflow) |
| Enable zero-trust A2A | Redeploy with `./scripts/setup.sh --with-a2a` (requires [Kagenti](https://github.com/kagenti/kagenti)) |
| Full architecture docs | [A2A-ARCHITECTURE.md](https://github.com/redhat-et/openclaw-k8s/blob/main/docs/A2A-ARCHITECTURE.md), [TEAMMATE-QUICKSTART.md](https://github.com/redhat-et/openclaw-k8s/blob/main/docs/TEAMMATE-QUICKSTART.md) |

## Links

- **Repository**: [github.com/redhat-et/openclaw-k8s](https://github.com/redhat-et/openclaw-k8s)
- **OpenClaw**: [github.com/openclaw](https://github.com/openclaw)
- **Kagenti** (zero-trust A2A): [github.com/kagenti/kagenti](https://github.com/kagenti/kagenti)
