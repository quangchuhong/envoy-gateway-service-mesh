{{- define "routing.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "routing.host" -}}
{{ .Values.hostPrefix }}.{{ .Values.domain }}
{{- end -}}

{{/* Phần đầu chung của mọi HTTPRoute: gắn vào listener https của eg-gateway, host shop.<domain> */}}
{{- define "routing.routeSpecHead" -}}
parentRefs:
  - name: {{ .Values.gateway.name }}
    namespace: {{ .Values.gateway.namespace }}
    sectionName: {{ .Values.gateway.sectionName }}
hostnames:
  - {{ include "routing.host" . | quote }}
{{- end -}}

{{/*
  Filter chung cho một rule (truyền tên rule):
  - extensionRef tới HTTPRouteFilter "to-anything": thêm tiền tố /anything vào path để go-httpbin echo lại
  - ResponseHeaderModifier: X-Route-Rule = tên rule (để test/quan sát rule nào đã khớp)
*/}}
{{- define "routing.ruleFilters" -}}
- type: ExtensionRef
  extensionRef:
    group: gateway.envoyproxy.io
    kind: HTTPRouteFilter
    name: to-anything
- type: ResponseHeaderModifier
  responseHeaderModifier:
    set:
      - name: X-Route-Rule
        value: {{ . }}
{{- end -}}

{{/* backendRef tới Service <tên>, gắn X-Routed-To vào response */}}
{{- define "routing.backend" -}}
- name: {{ . }}
  port: 8080
  filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
          - name: X-Routed-To
            value: {{ . }}
{{- end -}}
