# OpenClaw Helm Chart

## Files

| File | Purpose |
|------|---------|
| `Chart.yaml` | Chart metadata (v0.1.0) |
| `values.yaml` | All configurable values with defaults |
| `templates/_helpers.tpl` | Template helpers (labels, agent ID, secret generation, model auto-detection) |
| `templates/deployment.yaml` | Gateway deployment (conditionally includes oauth-proxy on OpenShift) |
| `templates/service.yaml` | ClusterIP service (conditionally includes oauth-ui port) |
| `templates/secrets.yaml` | openclaw-secrets + oauth-config (OpenShift) + telegram (optional) |
| `templates/configmap-config.yaml` | Gateway config (openclaw.json) with all model/tool/agent settings |
| `templates/configmap-shadowman.yaml` | Default agent persona and config |
| `templates/configmap-agent-card.yaml` | A2A agent discovery card |
| `templates/configmap-a2a-bridge.yaml` | A2A JSON-RPC bridge script |
| `templates/pvc.yaml` | Home (20Gi) + workspace (10Gi) PVCs |
| `templates/resourcequota.yaml` | Namespace resource limits |
| `templates/pdb.yaml` | Pod disruption budget |
| `templates/openshift-oauth.yaml` | ServiceAccount, ClusterRoleBinding, OAuthClient (OpenShift only) |
| `templates/openshift-route.yaml` | Route with TLS edge termination (OpenShift only) |
| `templates/NOTES.txt` | Post-install instructions |

## Usage

**OpenShift:**

Using a MaaS hosted model.

```bash
helm install openclaw chart/openclaw/ \
  --namespace claw --create-namespace \
  --set prefix=red \
  --set clusterDomain=apps.example.com \
  --set model.endpoint="https://maas.apps.example.com/maas/qwen35-9b/v1" \
  --set model.id="qwen35-9b" \
  --set model.name="Qwen35-9b" \
  --set model.contextWindow=60000 \
  --set model.maxTokens=60000 \
  --set model.apiKey="your-maas-token-here"
```

**Kubernetes:**

```bash
helm install openclaw chart/openclaw/ \
  --namespace claw --create-namespace \
  --set mode=kubernetes \
  --set prefix=red
```

## Design Decisions

- `mode: openshift` vs `mode: kubernetes` replaces the kustomize overlay system; OpenShift resources (OAuth proxy, Route, OAuthClient, serving-cert annotation) are conditionally included
- Secrets auto-generate if not provided (gateway token, OAuth secrets)
- Default agent model auto-derived from API key availability (Anthropic > Vertex > local), matching `setup.sh` behavior
- A2A disabled by default (`a2a.enabled: false`), sets `kagenti.io/inject: disabled` on the pod