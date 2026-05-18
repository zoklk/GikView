{{- define "emqx.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "emqx.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
{{- end }}
