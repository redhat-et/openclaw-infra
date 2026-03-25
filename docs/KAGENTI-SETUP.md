# Kagenti Platform Setup (OpenShift)

Repeatable steps for deploying the Kagenti zero-trust agent platform on a fresh OpenShift cluster. Tested on OCP 4.19.24 (ROSA).

## What Gets Installed

| Step | Helm Chart | Components | Namespace |
|------|-----------|------------|-----------|
| 1 | `kagenti-deps` | SPIRE (ZTWIM operator), cert-manager | `kagenti-system`, `zero-trust-workload-identity-manager` |
| 2 | `mcp-gateway` | MCP Gateway (Model Context Protocol) | `mcp-system` |
| 3 | `kagenti` | Keycloak, kagenti operator, webhook, UI | `kagenti-system`, `keycloak` |

After Kagenti is running, deploy agents (e.g. OpenClaw) with `kagenti.io/inject: enabled` labels — the webhook automatically injects Auth Identity Bridge sidecars.

## Prerequisites

- OpenShift 4.19+ (4.16+ works with Helm-based SPIRE fallback)
- `oc` or `kubectl` with **cluster-admin**
- `helm` >= 3.18.0
- Clone of kagenti repo — use [sallyom/kagenti](https://github.com/sallyom/kagenti) **branch `charts-updated-webhook`** until port exclusion annotation support is merged upstream. This branch overrides the webhook image with `quay.io/sallyom/kagenti-webhook:latest`, which adds `kagenti.io/outbound-ports-exclude` and `kagenti.io/inbound-ports-exclude` pod annotation support.

## Quick Start (Automated)

```bash
./scripts/setup-kagenti.sh
```

The script is interactive — it auto-detects your kagenti repo (expects `../kagenti` relative to this repo), prompts for agent namespaces, and runs all steps below. It's idempotent (safe to re-run) and supports `--dry-run` to preview commands.

Options:
```
--kagenti-repo PATH       Path to local kagenti repo clone
--agent-namespaces NS     Comma-separated namespaces for agent injection
--skip-ovn-patch          Skip OVN gateway routing patch
--skip-mcp-gateway        Skip MCP Gateway installation
--mcp-gateway-version VER MCP Gateway chart version (default: 0.4.0)
--dry-run                 Show commands without executing
```

## Manual Steps

### Step 0: Pre-flight

```bash
# Verify connectivity and version
oc version
oc whoami
kubectl get clusterversion version -o jsonpath='{.status.desired.version}'
```

### Step 1: OVN Gateway Patch

Required for OVNKubernetes clusters (most OCP clusters) to support Istio Ambient mode. Without this, health probes fail when ztunnel proxy is active.

```bash
kubectl patch network.operator.openshift.io cluster --type=merge \
  -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
```

### Step 2: Detect Trust Domain

```bash
export DOMAIN="apps.$(kubectl get dns cluster -o jsonpath='{ .spec.baseDomain }')"
echo "Trust domain: $DOMAIN"
```

### Step 3: Install kagenti-deps (SPIRE + cert-manager)

#### From local repo (recommended — use sallyom/kagenti branch charts-updated-webhook)

```bash
cd <path-to-kagenti-repo>

# If the cluster or a prior failed install already created chart-owned namespaces,
# adopt them before Helm install so it can manage them.
for ns in cert-manager istio-cni istio-system istio-ztunnel keycloak zero-trust-workload-identity-manager; do
  kubectl get namespace "$ns" >/dev/null 2>&1 || continue
  kubectl label namespace "$ns" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace "$ns" meta.helm.sh/release-name=kagenti-deps \
    meta.helm.sh/release-namespace=kagenti-system --overwrite
done

helm dependency update ./charts/kagenti-deps/
helm install kagenti-deps ./charts/kagenti-deps/ \
  -n kagenti-system --create-namespace \
  --set spire.trustDomain=${DOMAIN} --wait
```

#### From OCI registry (after fix is released)

```bash
LATEST_TAG=$(git ls-remote --tags --sort="v:refname" \
  https://github.com/kagenti/kagenti.git | tail -n1 | sed 's|.*refs/tags/v||; s/\^{}//')

helm install kagenti-deps oci://ghcr.io/kagenti/kagenti/kagenti-deps \
  -n kagenti-system --create-namespace \
  --version $LATEST_TAG \
  --set spire.trustDomain=${DOMAIN} --wait
```

#### Verify SPIRE

```bash
kubectl get daemonsets -n zero-trust-workload-identity-manager
# Both spire-agent and spire-spiffe-csi-driver should show READY = DESIRED

kubectl get pods -n zero-trust-workload-identity-manager
# spire-server, spire-agent (per node), csi-driver (per node), oidc-provider, controller-manager
```

### Step 4: Install MCP Gateway

```bash
helm install mcp-gateway oci://ghcr.io/kagenti/charts/mcp-gateway \
  --create-namespace --namespace mcp-system --version 0.4.0
```

### Step 5: Install Kagenti (Keycloak + operator + webhook + UI)

```bash
cd <path-to-kagenti-repo>

# Create secrets file (all fields optional for basic setup)
cp charts/kagenti/.secrets_template.yaml charts/kagenti/.secrets.yaml

# Update chart dependencies
helm dependency update ./charts/kagenti/

# Get latest tag for UI images
LATEST_TAG=$(git ls-remote --tags --sort="v:refname" \
  https://github.com/kagenti/kagenti.git | tail -n1 | sed 's|.*refs/tags/v||; s/\^{}//')

# Install — include all agent namespaces in agentNamespaces list.
# Kagenti creates AIB ConfigMaps (envoy-config, spiffe-helper-config,
# authbridge-config, environments) and SCC RoleBindings in each namespace.
# These are required for webhook-injected sidecars to start.
helm upgrade --install kagenti ./charts/kagenti/ \
  -n kagenti-system --create-namespace \
  -f ./charts/kagenti/.secrets.yaml \
  --set ui.frontend.tag=v${LATEST_TAG} \
  --set ui.backend.tag=v${LATEST_TAG} \
  --set 'agentNamespaces={sallyom-openclaw,bob-openclaw,nps-agent}' \
  --set agentOAuthSecret.spiffePrefix=spiffe://${DOMAIN}/sa \
  --set uiOAuthSecret.useServiceAccountCA=false \
  --set agentOAuthSecret.useServiceAccountCA=false
```

#### Adding agent namespaces after install

Agent namespaces must be registered with Kagenti so the webhook-injected sidecars get their required ConfigMaps. To add a namespace after initial install:

1. If the namespace already exists, label it for Helm adoption:
   ```bash
   kubectl label namespace <ns> app.kubernetes.io/managed-by=Helm --overwrite
   kubectl annotate namespace <ns> meta.helm.sh/release-name=kagenti \
     meta.helm.sh/release-namespace=kagenti-system --overwrite
   ```
2. Re-run `helm upgrade` with the updated `agentNamespaces` list.

### Step 6: Verify

```bash
# All pods running
kubectl get pods -n kagenti-system
kubectl get pods -n keycloak
kubectl get pods -n zero-trust-workload-identity-manager

# Kagenti UI URL
echo "https://$(kubectl get route kagenti-ui -n kagenti-system \
  -o jsonpath='{.status.ingress[0].host}')"

# Keycloak credentials
kubectl get secret keycloak-initial-admin -n keycloak \
  -o go-template='Username: {{.data.username | base64decode}}  Password: {{.data.password | base64decode}}{{"\n"}}'
```

### Step 7: Deploy OpenClaw Agent

Once Kagenti is healthy, deploy OpenClaw with Auth Identity Bridge enabled:

```bash
cd <path-to-openclaw-k8s>
./scripts/setup.sh --with-a2a
```

This sets `kagenti.io/inject: enabled` on the pod template — the kagenti-webhook automatically injects AIB sidecars (proxy-init, spiffe-helper, client-registration, envoy-proxy) at admission time.

On OpenShift, `setup.sh` also patches the webhook-injected `proxy-init` to exclude port 443 from iptables interception, so that `oauth-proxy` can reach the K8s API for token reviews. See [Known Issues: proxy-init port exclusion](#proxy-init-port-443-exclusion-openshift).

## Teardown

```bash
helm uninstall kagenti -n kagenti-system
helm uninstall mcp-gateway -n mcp-system
helm uninstall kagenti-deps -n kagenti-system
# Operators are retained (resource policy); delete namespaces to fully clean up
```

## Known Issues

### proxy-init port 443 exclusion (OpenShift)

The Kagenti webhook injects `proxy-init` with `OUTBOUND_PORTS_EXCLUDE="8080"` — this is the Kind/local default where Keycloak runs on HTTP port 8080. On OpenShift, the `oauth-proxy` sidecar needs direct access to the K8s API at `172.30.0.1:443` for token reviews and ConfigMap watches. Without port 443 excluded, proxy-init's iptables rules redirect that traffic through Envoy, causing connection timeouts:

```
dial tcp 172.30.0.1:443: connect: connection refused
```

**Current workaround**: `setup.sh --with-a2a` automatically patches the deployment after kustomize apply:
```bash
kubectl patch deployment openclaw -n $NS --type=strategic -p '{
  "spec": {"template": {"spec": {"initContainers": [{
    "name": "proxy-init",
    "env": [{"name": "OUTBOUND_PORTS_EXCLUDE", "value": "8080,443"}]
  }]}}}
}'
```

**Kagenti gap — file upstream issue**: The webhook should support per-pod port exclusion configuration, e.g. via pod annotation:
```yaml
annotations:
  kagenti.io/outbound-ports-exclude: "8080,443"
```
This would let workloads declare their own exclusions without post-deploy patches. Any pod with an oauth-proxy or other sidecar that talks to the K8s API will hit this issue.

### SPIRE operand CRD schema mismatch (pre-fix)

The `kagenti-deps` chart puts `clusterName` and `trustDomain` on child SPIRE CRs (SpireServer, SpireAgent, SpireOIDCDiscoveryProvider), but on OCP 4.19+ the ZTWIM CRD design centralizes these on the parent `ZeroTrustWorkloadIdentityManager` CR. Child CRDs reject unknown fields.

**Fix**: Use the local chart from the `charts-clustername-fix` branch, or install with `--no-hooks` and apply operand CRs manually.

### Helm 4 compatibility

Kagenti docs specify `helm >=3.18.0, <4` but Helm 4 works — it maintains backwards compatibility with Helm 3 charts. CLI flag deprecation warnings may appear.

### SCC for webhook-injected sidecars (OpenShift)

The webhook injects a `proxy-init` init container that runs as `privileged: true` (root, iptables setup). On OpenShift, the pod's service account must have access to an SCC that allows `allowPrivilegedContainer: true`. Kagenti's `agent-namespaces.yaml` grants `system:openshift:scc:privileged` to the `default` SA in each registered namespace. If using a custom service account, grant it separately.

### AgentCard CRD: selector vs targetRef

The AgentCard CRD accepts both `spec.selector.matchLabels` and `spec.targetRef`. The `selector` field is marked as deprecated — use `targetRef` when your CRD version supports it. Both work as of v0.5.0-alpha.

### `environments` ConfigMap field ownership conflict on `helm upgrade`

When Kagenti is first installed, the `agent-oauth-secret-job` (a K8s Job) writes `KEYCLOAK_ADMIN_USERNAME` and `KEYCLOAK_ADMIN_PASSWORD` to the `environments` ConfigMap in each agent namespace using the `OpenAPI-Generator` field manager. On subsequent `helm upgrade` commands, Helm's server-side apply fails because it doesn't own those fields:

```
Apply failed with 2 conflicts: conflicts with "OpenAPI-Generator" using v1:
- .data.KEYCLOAK_ADMIN_PASSWORD
- .data.KEYCLOAK_ADMIN_USERNAME
```

**Fix:** Delete the `environments` ConfigMaps before running `helm upgrade`:

```bash
for ns in bob-openclaw nps-agent; do
  kubectl delete configmap environments -n "$ns" 2>/dev/null || true
done
helm upgrade kagenti ...
```

### Agent namespaces must be registered with Kagenti

The webhook injects sidecars that mount 4 ConfigMaps (`envoy-config`, `spiffe-helper-config`, `authbridge-config`, `environments`). These are only created in namespaces listed in `agentNamespaces` during `helm install/upgrade`. Pods in unregistered namespaces will fail with `CreateContainerConfigError` (configmap not found). There is currently no dynamic namespace registration — this must be done via `helm upgrade` with an updated list.

**Kagenti gap — file upstream issue:** Ideally, labeling a namespace with `kagenti-enabled=true` should trigger the operator to bootstrap the 4 required ConfigMaps automatically. Today, the only mechanism is the static `agentNamespaces` list in the Helm chart's `agent-namespaces.yaml` template.

### AgentCard requires `/.well-known/agent.json` endpoint

The Kagenti operator's AgentCard controller fetches `/.well-known/agent.json` from the agent's service to populate the agent card in the UI. If the agent framework doesn't natively serve this A2A endpoint, the AgentCard will show `FetchFailed` status and the agent won't appear in the Kagenti UI.

**Current state:** OpenClaw's deployment includes an A2A bridge container (`agent-card`) that serves `/.well-known/agent.json` and also translates A2A JSON-RPC (`message/send`, `message/stream`) to OpenAI `/v1/chat/completions` requests against the local gateway. The bridge runs `a2a-bridge.py` — a Python stdlib HTTP server mounted from a ConfigMap.

```yaml
- name: agent-card
  image: registry.redhat.io/ubi9:latest
  command: ["python3", "-u", "/scripts/a2a-bridge.py"]
```

The agent card content comes from the `openclaw-agent-card` ConfigMap at `/srv/.well-known/agent.json`. The bridge script comes from the `a2a-bridge` ConfigMap at `/scripts/a2a-bridge.py`. See [A2A-ARCHITECTURE.md](A2A-ARCHITECTURE.md#a2a-bridge) for details.

Note: Use `ubi9` (not `ubi9-minimal`) — the minimal image does not include `python3`.

**Kagenti gap — file upstream issue:** The webhook should either:
1. Inject an agent-card server sidecar that serves `/.well-known/agent.json` (content from the AgentCard CR or a ConfigMap), or
2. The operator should populate agent info from the AgentCard CR spec alone without requiring a live HTTP fetch
