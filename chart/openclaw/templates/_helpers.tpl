{{/*
Expand the name of the chart.
*/}}
{{- define "openclaw.name" -}}
openclaw
{{- end }}

{{/*
Fullname — just "openclaw" (matches existing resource names).
*/}}
{{- define "openclaw.fullname" -}}
openclaw
{{- end }}

{{/*
Namespace derived from prefix.
*/}}
{{- define "openclaw.namespace" -}}
{{ .Release.Namespace }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "openclaw.labels" -}}
app: openclaw
app.kubernetes.io/name: openclaw
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "openclaw.selectorLabels" -}}
app: openclaw
{{- end }}

{{/*
Agent ID: <prefix>_<agent_name>
*/}}
{{- define "openclaw.agentId" -}}
{{ .Values.prefix }}_{{ .Values.agent.name }}
{{- end }}

{{/*
Init container image — auto-select based on mode.
*/}}
{{- define "openclaw.initImage" -}}
{{- if .Values.initImage -}}
{{ .Values.initImage }}
{{- else if eq .Values.mode "openshift" -}}
registry.redhat.io/ubi9-minimal:latest
{{- else -}}
busybox:latest
{{- end }}
{{- end }}

{{/*
Default agent model — derive from available API keys.
*/}}
{{- define "openclaw.defaultAgentModel" -}}
{{- if .Values.model.defaultAgentModel -}}
{{ .Values.model.defaultAgentModel }}
{{- else if .Values.secrets.anthropicApiKey -}}
anthropic/claude-sonnet-4-6
{{- else if .Values.vertex.enabled -}}
anthropic-vertex/claude-sonnet-4-6
{{- else -}}
local/{{ .Values.model.id }}
{{- end }}
{{- end }}

{{/*
Gateway token — use provided or generate a stable value.
Uses derivePassword to produce a deterministic value per release so that
multiple invocations within a single render return the same string.
On upgrade, existing secrets are looked up first to avoid regeneration.
*/}}
{{- define "openclaw.gatewayToken" -}}
{{- if .Values.secrets.gatewayToken -}}
{{ .Values.secrets.gatewayToken }}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace "openclaw-secrets" -}}
{{- if and $existing $existing.data (index $existing.data "OPENCLAW_GATEWAY_TOKEN") -}}
{{ index $existing.data "OPENCLAW_GATEWAY_TOKEN" | b64dec }}
{{- else -}}
{{ randAlphaNum 32 | b64enc }}
{{- end }}
{{- end }}
{{- end }}

{{/*
OAuth client secret — use provided or generate a stable value.
Looked up from the existing secret on upgrade to stay consistent.
*/}}
{{- define "openclaw.oauthClientSecret" -}}
{{- if .Values.secrets.oauthClientSecret -}}
{{ .Values.secrets.oauthClientSecret }}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace "openclaw-oauth-config" -}}
{{- if and $existing $existing.data (index $existing.data "client-secret") -}}
{{ index $existing.data "client-secret" | b64dec }}
{{- else -}}
{{ randAlphaNum 32 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
OAuth cookie secret — use provided or generate a stable value.
The oauth-proxy reads the mounted file as raw bytes and uses them directly
as the AES key, so the value must be exactly 16, 24, or 32 bytes.
*/}}
{{- define "openclaw.oauthCookieSecret" -}}
{{- if .Values.secrets.oauthCookieSecret -}}
{{ .Values.secrets.oauthCookieSecret }}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace "openclaw-oauth-config" -}}
{{- if and $existing $existing.data (index $existing.data "cookie_secret") -}}
{{ index $existing.data "cookie_secret" | b64dec }}
{{- else -}}
{{ randAlphaNum 32 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Allowed origins for the control UI.
*/}}
{{- define "openclaw.allowedOrigins" -}}
{{- if and (eq .Values.mode "openshift") .Values.clusterDomain -}}
["https://openclaw-{{ .Release.Namespace }}.{{ .Values.clusterDomain }}"]
{{- else -}}
[]
{{- end }}
{{- end }}
