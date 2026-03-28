# A2A Cross-Namespace Agent Communication

## Overview

OpenClaw instances communicate across Kubernetes namespaces using Google's [Agent-to-Agent (A2A)](https://github.com/google/A2A) protocol. Authentication is handled transparently by [Kagenti](https://github.com/kagenti/kagenti)'s Auth Identity Bridge (AIB) — webhook-injected sidecars that exchange SPIFFE workload identities for OAuth tokens via Keycloak.

This architecture demonstrates zero-trust agent communication where:
- Each OpenClaw instance has a cryptographic workload identity (SPIFFE)
- No shared secrets or API keys between instances
- All cross-namespace traffic is authenticated and auditable
- The gateway container remains fully hardened (read-only FS, dropped capabilities, no privilege escalation)
- Sidecars are injected automatically by the Kagenti webhook — no manual sidecar definitions needed

## Architecture

```
 Sally's Namespace (sallyom-openclaw)              Bob's Namespace (bob-openclaw)
 ┌────────────────────────────────────┐            ┌────────────────────────────────────┐
 │  OpenClaw Pod                      │            │  OpenClaw Pod                      │
 │                                    │            │                                    │
 │  ┌──────────┐    ┌──────────────┐  │            │  ┌──────────────┐    ┌──────────┐  │
 │  │  Lynx    │    │  A2A Bridge  │  │            │  │  A2A Bridge  │    │ Shadowman│  │
 │  │  Agent   │    │  :8080       │  │            │  │  :8080       │    │  Agent   │  │
 │  └────┬─────┘    └──────────────┘  │            │  └──────────────┘    └────┬─────┘  │
 │       │                            │            │                          │        │
 │  ┌────┴────────────────────────┐   │            │  ┌───────────────────────┴─────┐  │
 │  │     OpenClaw Gateway        │   │            │  │     OpenClaw Gateway        │  │
 │  │     :18789                  │   │            │  │     :18789                  │  │
 │  └─────────────────────────────┘   │            │  └────────────────────────────┘  │
 │                                    │            │                                    │
 │  ┌──────────────────────────────┐  │            │  ┌──────────────────────────────┐  │
 │  │  AIB Sidecars (Kagenti)      │  │  A2A/HTTP  │  │  AIB Sidecars (Kagenti)      │  │
 │  │  ┌─────────┐ ┌────────────┐  │  │◄──────────►│  │ ┌────────────┐ ┌─────────┐   │  │
 │  │  │ SPIFFE  │ │  Token     │  │  │            │  │ │   Token    │ │ SPIFFE  │   │  │
 │  │  │ Helper  │ │  Exchange  │  │  │            │  │ │  Exchange  │ │ Helper  │   │  │
 │  │  └─────────┘ └────────────┘  │  │            │  │ └────────────┘ └─────────┘   │  │
 │  └──────────────────────────────┘  │            │  └──────────────────────────────┘  │
 └────────────────────────────────────┘            └────────────────────────────────────┘
          │                                                    │
          ▼                                                    ▼
 ┌─────────────────┐                                ┌─────────────────┐
 │  SPIRE Agent    │         Trust Domain:          │  SPIRE Agent    │
 │  (DaemonSet)    │  apps.<cluster-domain>         │  (DaemonSet)    │
 └────────┬────────┘                                └────────┬────────┘
          │                                                  │
          ▼                                                  ▼
 ┌────────────────────────────────────────────────────────────────────┐
 │                      Keycloak (Kagenti-managed)                    │
 │   Clients auto-registered per SPIFFE ID                            │
 └────────────────────────────────────────────────────────────────────┘
```

## Message Flow

When Lynx (Sally's agent) sends a message to Shadowman (Bob's agent):

```
1. Lynx executes:  curl -X POST http://openclaw.bob-openclaw.svc.cluster.local:8080/

2. proxy-init iptables rules redirect outbound traffic to Envoy (:15123)

3. Envoy outbound listener:
   a. ext_proc filter calls token processor (:9090)
   b. Processor reads SPIFFE JWT from /opt/jwt_svid.token
   c. Processor exchanges SPIFFE JWT for Keycloak OAuth token
   d. OAuth token injected as Authorization header

4. Request arrives at Bob's pod → Envoy inbound listener (:15124)
   a. Validates OAuth token against Keycloak
   b. Strips auth header, forwards to agent-card (:8080)

5. A2A bridge on :8080 receives the request:
   a. For discovery (GET /.well-known/agent.json): serves the agent card
   b. For messages (POST / with A2A JSON-RPC): translates to OpenAI
      /v1/chat/completions against gateway (:18789) with x-openclaw-agent-id header

6. Response travels back through Envoy to Lynx
```

## Pod Components

With `--with-a2a` enabled, Kagenti webhook injects AIB sidecars at admission time. The resulting pod has:

### Init Containers

| Container | Image | Source | Purpose |
|-----------|-------|--------|---------|
| `init-config` | `ubi9-minimal` | Deployment manifest | Copies openclaw.json and agent configs to PVC |
| `proxy-init` | `kagenti-extensions/proxy-init` | Webhook-injected | iptables rules for transparent Envoy interception |

### Runtime Containers

| Container | Port | Source | Purpose |
|-----------|------|--------|---------|
| `gateway` | 18789 | Deployment manifest | OpenClaw agent runtime |
| `agent-card` | 8080 | Deployment manifest | A2A bridge: serves `/.well-known/agent.json` + translates A2A JSON-RPC to OpenAI chat completions |
| `oauth-proxy` | 8443 | Deployment manifest (OpenShift only) | OpenShift OAuth for UI access |
| `spiffe-helper` | - | Webhook-injected | Fetches X.509 + JWT SVIDs from SPIRE |
| `client-registration` | - | Webhook-injected | Registers OAuth client in Keycloak |
| `envoy-proxy` | 15123, 15124 | Webhook-injected | Transparent token exchange proxy |

Without `--with-a2a`, the pod has `init-config`, `gateway`, `agent-card` (A2A bridge), and `oauth-proxy` (OpenShift) — no Kagenti sidecars. The A2A bridge still serves `/.well-known/agent.json` and handles A2A JSON-RPC, but without AuthBridge sidecars, cross-namespace calls are unauthenticated.

## Kagenti Webhook Injection

Instead of manually defining AIB sidecars in the deployment manifest, the Kagenti webhook injects them automatically when:

1. The namespace is labeled `kagenti-enabled=true`
2. The pod template has label `kagenti.io/inject: enabled`

`setup.sh --with-a2a` sets both. The webhook adds `proxy-init`, `spiffe-helper`, `client-registration`, and `envoy-proxy` containers at Deployment create/update time.

### What the webhook provides
- Sidecar container definitions with correct images and env vars
- SPIRE CSI volume mounts for SPIFFE identity
- Shared volumes for credential exchange between sidecars

### What we still manage
- `agent-card` container (A2A bridge — serves `/.well-known/agent.json` and translates A2A JSON-RPC to gateway API)
- `oauth-proxy` sidecar (OpenShift-specific, not part of Kagenti)
- AgentCard CR (tells the Kagenti operator about our agent)
- Custom SCC (OpenShift — grants capabilities needed by injected sidecars)
- proxy-init port exclusion patch (port 443 for oauth-proxy K8s API access)

## A2A Bridge

The `agent-card` container runs an A2A bridge (`a2a-bridge.py`) — a Python stdlib HTTP server on `ubi9` that:

1. **Serves agent cards** — `GET /.well-known/agent.json` for Kagenti operator discovery
2. **Translates A2A JSON-RPC** — `POST /` with `message/send` or `message/stream` methods are translated to OpenAI `/v1/chat/completions` requests against the local gateway (:18789)
3. **Streams responses** — `message/stream` returns SSE events with `TaskStatusUpdateEvent` (state: `WORKING`) and `TaskArtifactUpdateEvent` (final response)

```yaml
- name: agent-card
  image: registry.redhat.io/ubi9:latest
  command: ["python3", "-u", "/scripts/a2a-bridge.py"]
  env:
  - name: GATEWAY_TOKEN
    valueFrom:
      secretKeyRef:
        name: openclaw-secrets
        key: OPENCLAW_GATEWAY_TOKEN
  - name: GATEWAY_URL
    value: "http://localhost:18789"
  - name: AGENT_ID
    value: ""  # Set by setup.sh; routes to specific agent via x-openclaw-agent-id header
```

The bridge script is mounted from the `a2a-bridge` ConfigMap at `/scripts/a2a-bridge.py`. Agent card content comes from the `openclaw-agent-card` ConfigMap at `/srv/.well-known/agent.json`.

Note: Use `ubi9` (not `ubi9-minimal`) — the minimal image does not include `python3`.

## AuthBridge (Zero-Trust Identity)

The AuthBridge pattern provides transparent mutual authentication between OpenClaw instances without application code changes. It consists of four sidecar containers injected by the Kagenti webhook:

### 1. SPIFFE Helper

Fetches workload identity credentials from the SPIRE agent via CSI volume:
- X.509 SVID certificate + key (for mTLS)
- JWT SVID token (for Keycloak exchange)
- Output: `/opt/svid.pem`, `/opt/svid_key.pem`, `/opt/jwt_svid.token`

Identity format: `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`

### 2. Client Registration

Waits for SPIFFE credentials, then registers the OpenClaw instance as an OAuth client in Keycloak:
- Client ID = SPIFFE ID (unique per namespace)
- Enables token exchange for outbound calls
- Writes credentials to `/shared/client-id.txt` and `/shared/client-secret.txt`

### 3. Envoy Proxy

Transparent proxy that intercepts all pod network traffic via iptables rules set by `proxy-init`:

- **Outbound** (port 15123): Calls `ext_proc` to exchange SPIFFE JWT for Keycloak OAuth token, injects `Authorization` header
- **Inbound** (port 15124): Validates incoming OAuth tokens against Keycloak before forwarding

### 4. Proxy Init (init container)

Configures iptables to redirect traffic through Envoy. Excluded ports prevent interception of internal and infrastructure traffic.

**OpenShift note:** The webhook injects proxy-init with `OUTBOUND_PORTS_EXCLUDE="8080"` (Kind default). On OpenShift, `setup.sh` patches this to `"8080,443"` so oauth-proxy can reach the K8s API (172.30.0.1:443) for token reviews. See [KAGENTI-SETUP.md](KAGENTI-SETUP.md#proxy-init-port-443-exclusion-openshift).

## Custom SCC (OpenShift)

The `openclaw-authbridge` SCC grants capabilities required by the webhook-injected AIB sidecars:

| Capability | Container | Reason |
|-----------|-----------|--------|
| `NET_ADMIN`, `NET_RAW` | proxy-init | iptables rules for transparent interception |
| `spc_t` SELinux | spiffe-helper, client-registration | Access SPIRE CSI volume |
| `RunAsAny` user | proxy-init (UID 0), envoy (UID 1337) | Sidecar runtime requirements |
| CSI volumes | spiffe-helper | SPIRE agent socket mount |

The SCC preserves `fsGroup: MustRunAs`, so the gateway container runs with the namespace-assigned GID in supplemental groups. The gateway's hardened security posture is unchanged:

```yaml
# Gateway container security (unchanged from restricted SCC)
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
    - ALL
```

## A2A Skill

The A2A skill (`agents/openclaw/skills/a2a/SKILL.md`) teaches agents how to communicate with other OpenClaw instances. It is deployed as a ConfigMap and copied into the agent's skill directory at `/home/node/.openclaw/skills/a2a/SKILL.md`.

The skill instructs agents to:

1. **Discover** remote agents via `curl ... /.well-known/agent.json | jq .`
2. **Send messages** via A2A `message/send` JSON-RPC
3. **Relay information** to local agents via `sessions_send`

Agents never handle authentication — the AuthBridge does it transparently. The skill uses only `curl` and `jq` (both in the gateway's `safeBins` allowlist).

## Cluster Prerequisites

A2A requires the Kagenti platform stack. Install it before deploying agents:

```bash
./scripts/kagenti-setup-works-for-sally.sh
```

See [KAGENTI-SETUP.md](KAGENTI-SETUP.md) for detailed steps. The stack provides:

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| SPIRE Server + Agent + CSI Driver | `zero-trust-workload-identity-manager` | Cryptographic workload identity (SPIFFE) |
| Keycloak | `keycloak` | OAuth token exchange, client registration |
| Kagenti Operator + Webhook | `kagenti-system` | Sidecar injection, agent discovery |
| MCP Gateway | `mcp-system` | Model Context Protocol gateway |

## Deployment

### Setup

```bash
# 1. Install Kagenti platform (SPIRE, Keycloak, operator, webhook)
./scripts/kagenti-setup-works-for-sally.sh

# 2. Deploy OpenClaw with A2A enabled
./scripts/setup.sh --with-a2a

# 3. Deploy agents (optional — adds resource-optimizer, cron jobs)
./scripts/setup-agents.sh
```

### Verification

```bash
# Check all containers are running
oc get pods -l app=openclaw -n <namespace>

# Check agent card
curl -s http://openclaw.<namespace>.svc.cluster.local:8080/.well-known/agent.json | jq .

# Check SPIFFE identity
oc exec deployment/openclaw -c spiffe-helper -- cat /opt/jwt_svid.token | \
  cut -d. -f2 | base64 -d 2>/dev/null | jq .sub

# Test cross-namespace A2A call
oc exec deployment/openclaw -c gateway -- \
  curl -s -X POST http://openclaw.<remote-namespace>.svc.cluster.local:8080/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Hello from my namespace"}]}}}'
```

## Files

| File | Description |
|------|-------------|
| `agents/openclaw/base/openclaw-deployment.yaml` | Pod spec (gateway, agent-card/a2a-bridge, init-config) |
| `agents/openclaw/base/openclaw-agent-card-configmap.yaml` | Agent card ConfigMap (/.well-known/agent.json) |
| `agents/openclaw/a2a-bridge/a2a-bridge.py` | A2A-to-OpenAI bridge script |
| `agents/openclaw/a2a-bridge/kustomization.yaml` | Bridge ConfigMap generator |
| `platform/auth-identity-bridge/openclaw-scc.yaml` | Custom SCC for AIB sidecars |
| `platform/auth-identity-bridge/openclaw-agentcard.yaml.envsubst` | AgentCard CR for Kagenti operator |
| `agents/openclaw/skills/a2a/SKILL.md` | A2A skill for agents |
| `agents/openclaw/skills/kustomization.yaml` | Skill ConfigMap generator |
| `agents/openclaw/skills/install-a2a-skill.sh` | Install skill into running pod |
| `scripts/kagenti-setup-works-for-sally.sh` | Working OpenShift Kagenti platform installation script |
| `docs/KAGENTI-SETUP.md` | Kagenti setup guide and known issues |

## Limitations

- **Single-turn**: Each `message/send` creates a new session — no multi-turn conversation context across calls
- **A2A bridge container**: Kagenti webhook does not inject an A2A bridge. We add one manually using `ubi9` + `a2a-bridge.py` (ConfigMap-mounted script). Upstream issue needed for webhook-injected agent-card/bridge support.
- **proxy-init port exclusion**: Webhook hardcodes `OUTBOUND_PORTS_EXCLUDE="8080"`. On OpenShift, `setup.sh` patches to add port 443. Upstream issue needed for annotation-based configuration.
- **K8s mode**: When deployed with `--k8s` without `--with-a2a`, no AIB sidecars are present. Cross-namespace calls work but are unauthenticated.
