{{- define "prometheus.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "prometheus.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
{{- end }}
