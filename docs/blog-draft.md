# Deploy OpenClaw on OpenShift in 5 Minutes

OpenClaw is an open-source AI agent gateway — a single Node.js process that coordinates agents, tools, and sessions through HTTP and WebSocket on a single port. It connects to model providers (Anthropic, OpenAI, Google, etc.) over HTTPS and serves a web UI for interacting with your agents.

This guide gets you from zero to a running OpenClaw instance on OpenShift, with OAuth protecting the UI and enterprise security hardening out of the box.

## Why OpenShift?

OpenClaw runs on any Kubernetes cluster, but OpenShift adds layers of security that matter when you're running AI agents that can call tools, execute code, and interact with external services.

### What OpenShift gives you for free

**OAuth integration** — OpenClaw's deployment includes an [oauth-proxy](https://github.com/openshift/oauth-proxy) sidecar that authenticates users against OpenShift's built-in OAuth server. No external identity provider to configure. If you can `oc login`, you can access your agent.

**Security Context Constraints (SCCs)** — OpenShift's default `restricted-v2` SCC enforces a strict posture on every container:

- Runs as a random, non-root UID assigned by the namespace
- Read-only root filesystem
- All Linux capabilities dropped
- No privilege escalation

The OpenClaw gateway runs happily under `restricted-v2` with no custom SCC required. Every container in the pod — gateway, oauth-proxy, and init-config — runs unprivileged with `allowPrivilegeEscalation: false` and `capabilities.drop: [ALL]`. OpenShift assigns an arbitrary UID from the namespace's allocated range at runtime, and because the container image is built with GID 0 permissions, everything just works.

**Routes with TLS** — OpenShift Routes provide automatic TLS termination via the cluster's wildcard certificate. The gateway listens on loopback only (`127.0.0.1:18789`) — all external traffic goes through the oauth-proxy, which handles authentication before forwarding to the gateway. OpenShift's HAProxy-based Ingress Controller handles WebSocket natively — after the HTTP upgrade handshake completes, it treats the connection as a bidirectional TCP tunnel. No special annotation needed.

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

A few things worth noting about this architecture:

- **Single port.** HTTP health checks and WebSocket upgrades share port 18789. No sidecar or second port needed for health probes.
- **Filesystem-backed state.** All persistent state — session transcripts (JSONL files), agent memory (SQLite with vector search), and configuration (JSON5) — lives on a single PVC. There is no external database. Backup reduces to a volume snapshot.
- **Single replica.** OpenClaw's session transcripts and memory index don't support concurrent writers, so this deployment uses a single replica with a Recreate strategy. This avoids a deadlock that occurs with RollingUpdate and ReadWriteOnce PVCs: the new pod can't mount the volume until the old pod releases it, but the old pod won't terminate until the new one is Ready.

### What the platform deploys

Beyond the pod, the setup script creates namespace-level security resources:

| Resource | Purpose |
|----------|---------|
| **ResourceQuota** | Caps the namespace at 4 CPU / 8Gi RAM requests, 20 pods, 100Gi storage |
| **PodDisruptionBudget** | `maxUnavailable: 0` — protects the pod during node maintenance |
| **ServiceAccount** | Dedicated SA for the oauth-proxy (no API permissions granted) |
| **OAuthClient** | Cluster-scoped — registers the instance with OpenShift's OAuth server |

The gateway container has zero Kubernetes API permissions. It talks to model providers over HTTPS and serves the UI on loopback. That's it.

## Prerequisites

- An OpenShift cluster where you can create a namespace
- `oc` CLI authenticated (`oc login`)
- An API key for at least one model provider (Anthropic, OpenAI, Google, etc.)

The OAuthClient is a cluster-scoped resource. If you don't have cluster-admin, the script will print the exact command to give your admin — it's a single `oc apply`.

**A note on storage:** OpenClaw uses SQLite for its agent memory index, which requires POSIX file locking via `fcntl()`. Your cluster's default block storage class (gp3-csi on AWS, managed-csi on Azure, thin-csi on vSphere) works correctly. Avoid NFS-backed storage classes — they don't reliably support the locking SQLite requires and can cause silent data corruption.

## Deploy

```bash
git clone https://github.com/redhat-et/openclaw-k8s.git
cd openclaw-k8s
./scripts/setup.sh
```

The script is interactive. It will prompt you for:

1. **Namespace prefix** — your name or team (e.g., `alice`). Creates the namespace `alice-openclaw`.
2. **Agent name** — a display name for your default agent (e.g., `Atlas`, `Scout`, `Raven`).
3. **API key** — for your model provider. The script detects `ANTHROPIC_API_KEY` from your environment automatically, or prompts for it.

Everything else is auto-generated (gateway token, OAuth secrets, cookie secrets) and saved to `.env` (git-ignored).

The script builds a `generated/` directory with processed templates, deploys via kustomize, waits for the pod to be ready, and installs agent workspace files. Total time: about 2 minutes, most of it waiting for the image pull.

## Access your instance

The Route URL is printed at the end of setup:

```
Access URLs:
  OpenClaw Gateway:   https://openclaw-alice-openclaw.apps.your-cluster.example.com
```

OpenShift OAuth handles authentication — you'll be redirected to the OpenShift login page. After authenticating, the Control UI asks for your **Gateway Token**:

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

Open the WebChat UI from the Control UI sidebar, select your agent, and start chatting. The agent has access to the tools configured in your gateway — by default, a general-purpose assistant backed by your chosen model.

### Create your own agent

The `add-agent.sh` script handles the full lifecycle — scaffolding files, deploying the ConfigMap, registering the agent in the live config, and installing workspace files:

```bash
./scripts/add-agent.sh
```

It prompts for an agent ID, display name, description, and optional scheduled job, then deploys everything and restarts the gateway. Your new agent is ready to chat immediately.

## Model options

The setup script supports multiple model providers. You can also change models after deployment by editing the config.

| Provider | Model | How to configure |
|----------|-------|-----------------|
| Anthropic | `anthropic/claude-sonnet-4-6` | `ANTHROPIC_API_KEY` env var or interactive prompt |
| OpenAI | `openai/gpt-4o` | Interactive prompt during setup |
| Google Vertex AI | `google-vertex/gemini-2.5-pro` | `--vertex` flag, requires GCP project |
| Claude via Vertex | `anthropic-vertex/claude-sonnet-4-6` | `--vertex --vertex-provider anthropic` |
| In-cluster vLLM | Any model on your GPU node | Set `MODEL_ENDPOINT` to your vLLM `/v1` URL |

## Day-2 operations

**Re-deploying safely** — You can re-run `setup.sh` at any time — to pick up a new API key, change a .env setting, or upgrade. The script detects if your live config has drifted from the templates (agents you've added, settings you've changed) and prompts you to preserve it. Your agents and config changes survive the re-deploy. Use `--preserve-config` to skip the prompt and always preserve.

**Preserving UI changes** — The gateway writes config changes to the PVC, but the init container overwrites from the ConfigMap on every restart. If you've tweaked settings through the Control UI, run `./scripts/sync-config.sh` to push the live config back to the ConfigMap so your changes survive restarts. The next time you run `setup.sh`, it will detect these synced changes and offer to keep them.

**Backing up state** — All persistent state lives on the PVC. Use a VolumeSnapshot to back it up.

**Monitoring** — The gateway is CPU-light but memory usage grows with active agents and session transcripts held in memory. Use `oc adm top pods` to watch resource consumption.

## Teardown

```bash
./scripts/teardown.sh
```

Removes the namespace, all resources, the OAuthClient, and the `generated/` directory. Your `.env` is kept unless you pass `--delete-env`.

## Next steps

| What | How |
|------|-----|
| Create a custom agent | `./scripts/add-agent.sh` |
| Add scheduled jobs | Create a `JOB.md` in your agent directory, run `./scripts/update-jobs.sh` |
| Enable observability | `./scripts/deploy-otelcollector.sh` (requires OTEL Operator + MLflow) |
| Connect agents across clusters | Redeploy with `./scripts/setup.sh --with-a2a` to enable zero-trust agent-to-agent communication via [Google A2A](https://github.com/google/A2A) protocol with [Kagenti](https://github.com/kagenti/kagenti) (SPIFFE/SPIRE + Keycloak). See [A2A-ARCHITECTURE.md](https://github.com/redhat-et/openclaw-k8s/blob/main/docs/A2A-ARCHITECTURE.md) |
| Full architecture docs | [TEAMMATE-QUICKSTART.md](https://github.com/redhat-et/openclaw-k8s/blob/main/docs/TEAMMATE-QUICKSTART.md) |

## Links

- **Repository**: [github.com/redhat-et/openclaw-k8s](https://github.com/redhat-et/openclaw-k8s)
- **OpenClaw**: [github.com/openclaw](https://github.com/openclaw)
- **Kagenti** (zero-trust A2A): [github.com/kagenti/kagenti](https://github.com/kagenti/kagenti)
