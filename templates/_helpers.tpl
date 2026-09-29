{{- define "owlpane.appName" -}}owlpane{{- end -}}
{{- define "owlpane.rbacId" -}}owlpane-agent{{- end -}}
{{- define "owlpane.sa" -}}{{ if .Values.serviceAccount.name }}{{ .Values.serviceAccount.name }}{{ else }}{{ include "owlpane.rbacId" . }}{{ end }}{{- end -}}
{{- define "owlpane.labels" -}}
app.kubernetes.io/name: {{ include "owlpane.appName" . }}
app.kubernetes.io/part-of: owlpane
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
{{- define "owlpane.require" -}}
{{- if not .Values.endpoint }}{{ fail "endpoint is required (your Owlpane ingest URL)" }}{{ end -}}
{{- if not .Values.cluster.name }}{{ fail "cluster.name is required" }}{{ end -}}
{{- end -}}
{{- define "owlpane.exporter" -}}
otlp_http:
  endpoint: {{ .Values.endpoint | trimSuffix "/" | quote }}
  headers:
    Authorization: "Bearer ${env:OWLPANE_INGEST_KEY}"
  compression: gzip
  timeout: 15s
  retry_on_failure: { enabled: true, initial_interval: 2s, max_interval: 30s, max_elapsed_time: 300s }
  sending_queue: { enabled: true, queue_size: 1000 }
{{- end -}}
{{- define "owlpane.nodeAgentMerged" -}}
{{- mergeOverwrite (dict "enabled" true "hostmetrics" (dict "enabled" true) "resourcedetection" (dict "enabled" true) "extraEnv" (list) "kubeletInsecureSkipVerify" false "collectionInterval" "30s" "otlpHostPort" false) (default dict .Values.nodeAgent) | toYaml -}}
{{- end -}}
{{- define "owlpane.standaloneCollectorMerged" -}}
{{- mergeOverwrite (dict "enabled" false "hostmetrics" (dict "enabled" true) "resourcedetection" (dict "enabled" true) "resources" (dict)) (default dict .Values.standaloneCollector) | toYaml -}}
{{- end -}}
{{- define "owlpane.carbonMerged" -}}
{{- mergeOverwrite (dict "region" "" "kepler" (dict "enabled" false "port" 28282 "image" (dict "repository" "quay.io/sustainable_computing_io/kepler" "tag" "v0.12.0") "resources" (dict "requests" (dict "cpu" "50m" "memory" "128Mi") "limits" (dict "memory" "400Mi")) "tolerations" (list (dict "operator" "Exists")))) (default dict .Values.carbon) | toYaml -}}
{{- end -}}
{{- define "owlpane.nodeOtelResourceAttributes" -}}
{{- $carbon := include "owlpane.carbonMerged" . | fromYaml -}}
{{- $na := include "owlpane.nodeAgentMerged" . | fromYaml -}}
{{- $rd := index $na "resourcedetection" | default dict -}}
{{- if index $rd "enabled" | default true -}}
{{- $region := index $carbon "region" | default "" -}}
{{- if $region -}}host.name=$(K8S_NODE_NAME),cloud.region={{ $region }}{{- else -}}host.name=$(K8S_NODE_NAME){{- end -}}
{{- end -}}
{{- end -}}
{{- define "owlpane.env" -}}
- name: OWLPANE_INGEST_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.ingestKeySecret.name }}
      key: {{ .Values.ingestKeySecret.key }}
- name: K8S_NODE_NAME
  valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
- name: K8S_NODE_IP
  valueFrom: { fieldRef: { fieldPath: status.hostIP } }
- name: K8S_POD_IP
  valueFrom: { fieldRef: { fieldPath: status.podIP } }
- name: GOMEMLIMIT
  value: "200MiB"
{{- end -}}
{{- define "owlpane.k8sattributes" -}}
k8s_attributes:
  passthrough: false
  auth_type: serviceAccount
  filter:
    node_from_env_var: K8S_NODE_NAME
  extract:
    metadata: [k8s.namespace.name, k8s.pod.name, k8s.pod.uid, k8s.node.name, k8s.deployment.name, k8s.statefulset.name, k8s.daemonset.name, k8s.cronjob.name, k8s.job.name, k8s.container.name, container.image.name, container.image.tag]
    {{- with .Values.metadata.labels }}
    labels:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with .Values.metadata.annotations }}
    annotations:
{{ toYaml . | indent 6 }}
    {{- end }}
  pod_association:
    - sources: [{ from: resource_attribute, name: k8s.pod.ip }]
    - sources: [{ from: resource_attribute, name: k8s.pod.uid }]
    - sources: [{ from: connection }]
{{- end -}}
{{- define "owlpane.redact" -}}
# Personal data and secrets removed here, on the customer's own node, before anything leaves the
# cluster — not just re-checked server-side. Query strings can carry tokens (OAuth codes, signed
# URLs): keep the path, drop the query.
transform/scrub_urls:
  error_mode: ignore
  trace_statements:
    - context: span
      statements:
        - replace_pattern(attributes["url.full"], "\\?.*$", "")
        - replace_pattern(attributes["http.url"], "\\?.*$", "")
        - replace_pattern(attributes["http.target"], "\\?.*$", "")
  log_statements:
    - context: log
      statements:
        - replace_pattern(attributes["url.full"], "\\?.*$", "")
        - replace_pattern(attributes["req.url"], "\\?.*$", "")
        - replace_pattern(attributes["req"], "\"remoteAddress\":\"[^\"]*\"", "\"remoteAddress\":\"[redacted]\"")
        - replace_pattern(attributes["req"], "\"url\":\"([^\"?]*)\\?[^\"]*\"", "\"url\":\"$$1\"")
# SQL literals become "?", so a query keeps its shape and loses its values; free text (log bodies,
# exception messages) loses emails, bearer tokens, card-like numbers and password/token/secret
# values. The bracketed markers below ([email], [token], [number], [redacted]) are also what the
# owlpane.redactionCounter connector looks for, so this processor and that metric must stay in step.
transform/redact:
  error_mode: ignore
  trace_statements:
    - context: span
      statements:
        - replace_pattern(attributes["db.statement"], "'(?:[^']|'')*'", "?")
        - replace_pattern(attributes["db.statement"], "\\b\\d+(?:\\.\\d+)?\\b", "?")
        - replace_pattern(attributes["db.query.text"], "'(?:[^']|'')*'", "?")
        - replace_pattern(attributes["db.query.text"], "\\b\\d+(?:\\.\\d+)?\\b", "?")
        - replace_pattern(attributes["exception.message"], "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "[email]")
        - replace_pattern(attributes["exception.message"], "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+", "Bearer [token]")
        - replace_pattern(attributes["exception.message"], "\\b(?:\\d[ -]?){13,19}\\b", "[number]")
        - replace_pattern(attributes["exception.message"], "\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b", "[cloud-key]")
        - replace_pattern(attributes["exception.message"], "\\bAIza[0-9A-Za-z\\-_]{35}\\b", "[cloud-key]")
        - replace_pattern(attributes["exception.message"], "\\bghp_[A-Za-z0-9]{20,}\\b", "[cloud-key]")
        - replace_pattern(attributes["exception.message"], "\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b", "[cloud-key]")
        - replace_pattern(attributes["exception.message"], "(?i)(password|passwd|secret|api[_-]?key|token)([\"']?\\s*[:=]\\s*[\"']?)[^\\s\"',}&]+", "$$1$$2[redacted]")
  log_statements:
    - context: log
      statements:
        - replace_pattern(body, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "[email]")
        - replace_pattern(body, "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+", "Bearer [token]")
        - replace_pattern(body, "\\b(?:\\d[ -]?){13,19}\\b", "[number]")
        - replace_pattern(body, "\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b", "[cloud-key]")
        - replace_pattern(body, "\\bAIza[0-9A-Za-z\\-_]{35}\\b", "[cloud-key]")
        - replace_pattern(body, "\\bghp_[A-Za-z0-9]{20,}\\b", "[cloud-key]")
        - replace_pattern(body, "\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b", "[cloud-key]")
        - replace_pattern(body, "(?i)(password|passwd|secret|api[_-]?key|token)([\"']?\\s*[:=]\\s*[\"']?)[^\\s\"',}&]+", "$$1$$2[redacted]")
{{- end -}}
{{- define "owlpane.redactionCounter" -}}
# Proof the control runs, not just a claim: counts spans and log records that carry one of the
# redaction markers transform/redact just wrote, as their own metric, exported like any other.
count:
  spans:
    owlpane.redactions.spans:
      description: "Spans with a value removed by edge redaction (see owlpane.redact)"
      conditions:
        - 'IsMatch(attributes["exception.message"], "\\[(email|token|number|redacted|cloud-key)\\]")'
  logs:
    owlpane.redactions.logs:
      description: "Log records with a value removed by edge redaction (see owlpane.redact)"
      conditions:
        - 'IsMatch(body, "\\[(email|token|number|redacted|cloud-key)\\]")'
    owlpane.redactions.cards:
      description: "Log records whose card-shaped number was removed before export"
      conditions:
        - 'IsMatch(body, "\\[number\\]")'
    owlpane.redactions.cloud_keys:
      description: "Log records whose cloud key was removed before export"
      conditions:
        - 'IsMatch(body, "\\[cloud-key\\]")'
    owlpane.redactions.tokens:
      description: "Log records whose bearer token was removed before export"
      conditions:
        - 'IsMatch(body, "\\[token\\]")'
{{- end -}}
