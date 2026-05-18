{{- define "mapping-generator.fullname" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "mapping-generator.serviceAccountName" -}}
{{- default .Chart.Name .Values.serviceAccount.name -}}
{{- end -}}

{{- define "mapping-generator.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{- define "mapping-generator.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
