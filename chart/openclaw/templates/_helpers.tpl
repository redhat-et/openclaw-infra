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
local/openai/gpt-oss-20b
{{- end }}
{{- end }}

{{/*
Gateway token — use provided or generate.
*/}}
{{- define "openclaw.gatewayToken" -}}
{{- if .Values.secrets.gatewayToken -}}
{{ .Values.secrets.gatewayToken }}
{{- else -}}
{{ randAlphaNum 32 | b64enc }}
{{- end }}
{{- end }}

{{/*
OAuth client secret — use provided or generate.
*/}}
{{- define "openclaw.oauthClientSecret" -}}
{{- if .Values.secrets.oauthClientSecret -}}
{{ .Values.secrets.oauthClientSecret }}
{{- else -}}
{{ randAlphaNum 32 | b64enc }}
{{- end }}
{{- end }}

{{/*
OAuth cookie secret — use provided or generate.
The oauth-proxy reads the mounted file as raw bytes and uses them directly
as the AES key, so the value must be exactly 16, 24, or 32 bytes.
*/}}
{{- define "openclaw.oauthCookieSecret" -}}
{{- if .Values.secrets.oauthCookieSecret -}}
{{ .Values.secrets.oauthCookieSecret }}
{{- else -}}
{{ randAlphaNum 32 }}
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
