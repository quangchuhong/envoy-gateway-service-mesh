{{- define "demo.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "demo.host" -}}
{{ .Values.hostPrefix }}.{{ .Values.domain }}
{{- end -}}

{{- define "demo.parentRef" -}}
- name: {{ .Values.gateway.name }}
  namespace: {{ .Values.gateway.namespace }}
  sectionName: {{ .Values.gateway.sectionName }}
{{- end -}}
