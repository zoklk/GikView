{{- define "alertmanager.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "alertmanager.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
{{- end }}
