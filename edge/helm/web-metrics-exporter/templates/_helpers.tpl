{{- define "web-metrics-exporter.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "web-metrics-exporter.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
{{- end }}
