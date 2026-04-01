# Teammate Quickstart

Get your own OpenClaw instance running in minutes.

## What You Need

- Access to the cluster (`oc login` or `kubectl` configured)
- (Optional) An Anthropic API key for Claude-powered agents

## Model Options

OpenClaw agents need an LLM endpoint. You have several options:

| Option | When to Use | Details |
|--------|------------|---------|
| **Anthropic API key** | You have an Anthropic API key and want to use Claude | Agents use `anthropic/claude-sonnet-4-6` |
| **Anthropic via Vertex** | Your org has Claude enabled on GCP Vertex AI | **Known limitation:** The OpenClaw gateway's `anthropic-messages` adapter calls `baseUrl + /v1/messages`, but Vertex AI uses a different path (`/v1/projects/.../locations/.../publishers/anthropic/models/...:predict`). This results in **404** when chatting. Until the gateway supports Vertex's path, use **option 1 (Anthropic API key)** for Claude, or **option 2 with provider "google"** for Gemini on Vertex. |
| **Google Vertex AI** | Your org has a GCP project with Vertex AI enabled | Choose option 2 (Vertex) at setup, then pick provider **google**. Agents use `google-vertex/gemini-2.5-pro`, billed through GCP. |
| **In-cluster vLLM** | Your cluster has a GPU node with vLLM deployed | Default `MODEL_ENDPOINT`: `http://vllm.openclaw-llms.svc.cluster.local/v1` |
| **Your own endpoint** | You already have an OpenAI-compatible model server | Supply your server's `/v1` URL as `MODEL_ENDPOINT` |

## Step 1: Deploy Your OpenClaw

```bash
git clone <this-repo>
cd openclaw-k8s

./scripts/setup.sh           # OpenShift
./scripts/setup.sh --k8s     # Kubernetes (KinD, minikube, etc.)
```

The script prompts you for:

1. **Namespace prefix** — use your name (e.g., `bob`). Creates `bob-openclaw`.
2. **Agent name** — pick a name for your agent (e.g., `Shadowman`, `Lynx`, `Atlas`).
3. **LLM source** — choose one: (1) Anthropic API key, (2) Google Vertex AI (Claude or Gemini), or (3) local/in-cluster model. You are then prompted only for the details of that choice (e.g. for Vertex: project ID, provider [anthropic is default], region, service account JSON path).

After setup completes, your instance has:
- A gateway with your named agent
- Control UI + WebChat

## Step 2: Access Your Platform

**OpenShift** — URL shown at the end of `setup.sh` output:
```
OpenClaw Gateway:  https://openclaw-<prefix>-openclaw.apps.YOUR-CLUSTER.com
```

The UI uses OpenShift OAuth. In the Control UI, go to **Overview** and paste your **Gateway Token** into the Gateway token field:
```bash
grep OPENCLAW_GATEWAY_TOKEN .env
```

**Kubernetes** — port-forward:
```bash
kubectl port-forward svc/openclaw 18789:18789 -n <prefix>-openclaw
# Open http://localhost:18789
```

## Step 3: Add Your Own Agents

Deploy the included repo-watcher agent to try it out:

```bash
./scripts/add-agent.sh repo-watcher
```

This deploys an agent that monitors the openclaw/openclaw GitHub repo for
recent commits and PRs every 2 hours, then reports findings to your default
agent. It uses `curl` and `jq` against the public GitHub API.

See [Create Your Own Agent](#create-your-own-agent) below for how to build
your own agents with AI assistance.

## Step 4: Enable A2A Communication (Optional, Advanced)

To enable cross-namespace agent communication with zero-trust authentication, redeploy with A2A:

```bash
./scripts/teardown.sh && ./scripts/setup.sh --with-a2a        # OpenShift
./scripts/teardown.sh --k8s && ./scripts/setup.sh --k8s --with-a2a  # Kubernetes
```

This requires SPIRE + Keycloak infrastructure on your cluster. The script will prompt for Keycloak configuration. With A2A enabled, your instance gets:
- An **A2A bridge** sidecar (port 8080) so other instances can discover and message your agent
- **AuthBridge** sidecars (SPIFFE + Envoy) for transparent zero-trust identity
- An **A2A skill** so your agent knows how to talk to other instances

On **OpenShift**, `setup.sh --with-a2a` automatically applies the AuthBridge SCC and RBAC grant. If it fails (needs cluster-admin), the script prints the exact commands to give your admin.

See [A2A-ARCHITECTURE.md](A2A-ARCHITECTURE.md) for the full architecture.

## Create Your Own Agent

To create an agent, you write **one file**: `AGENTS.md` — the agent's instructions.
Everything else (metadata, ConfigMap, registration) is generated automatically.

### Option A: Write It with AI (recommended)

Ask your AI assistant (Claude Code, Copilot, etc.) to create the AGENTS.md for you.
Point it at `agents/openclaw/agents/repo-watcher/` as a reference.

**Example prompt:**

> Look at agents/openclaw/agents/repo-watcher/AGENTS.md.envsubst for the format.
> Create a new agent called "pr-reviewer" that reviews open PRs in our repo every
> morning and posts a summary to my default agent. Create AGENTS.md.envsubst and JOB.md.

Your AI creates the agent directory:
```
agents/openclaw/agents/pr-reviewer/
  AGENTS.md.envsubst       # ← Agent instructions (you write this)
  JOB.md                   # ← Cron schedule (optional)
```

Then deploy — the script generates `agent.json` and the ConfigMap automatically:
```bash
./scripts/add-agent.sh pr-reviewer
```

### Option B: Start from Template

```bash
./scripts/add-agent.sh --scaffold-only example-agent "Example Agent" "Monitors system health"
```

This creates the directory with all files. Edit `AGENTS.md.envsubst` to write
your agent's instructions, then deploy:

```bash
./scripts/add-agent.sh example-agent
```

### Agent File Structure

Each agent directory contains:

| File | Purpose | Who writes it |
|------|---------|---------------|
| `AGENTS.md.envsubst` | Agent instructions (persona, tools, behavior) | You |
| `JOB.md` | Cron job schedule and message (optional) | You |
| `agent.json.envsubst` | Metadata (name, emoji, color) | Generated by script |
| `*-agent.yaml.envsubst` | ConfigMap shell | Generated by script |

Use `${OPENCLAW_PREFIX}` and `${OPENCLAW_NAMESPACE}` for values that vary per
deployment. See [agents/openclaw/agents/_template/README.md](../agents/openclaw/agents/_template/README.md)
for the full reference.

### Adding a Scheduled Job

Include a `JOB.md` in your agent's directory:

```markdown
---
id: security-scanner-job
schedule: "0 */4 * * *"
tz: UTC
---

Check deployed images for known CVEs. Report critical findings
to ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME} via sessions_send.
```

The deploy script detects the JOB.md and sets up the cron automatically.

| Schedule | Expression |
|----------|-----------|
| Every 2 hours | `0 */2 * * *` |
| Every day at 9 AM UTC | `0 9 * * *` |
| Weekdays at 9 AM and 5 PM | `0 9,17 * * 1-5` |
