{{- define "eg-platform.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: eg-platform
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}


{{/* Annotation cho NLB (AWS Load Balancer Controller) */}}
{{- define "eg-platform.serviceAnnotations" -}}
{{- $s := .Values.envoyProxy.service -}}
{{- if and (eq $s.type "LoadBalancer") $s.nlb.enabled }}
service.beta.kubernetes.io/aws-load-balancer-type: external
service.beta.kubernetes.io/aws-load-balancer-scheme: {{ $s.nlb.scheme }}
service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: preserve_client_ip.enabled={{ $s.nlb.preserveClientIP }},deregistration_delay.timeout_seconds={{ $s.nlb.deregistrationDelaySeconds }}
{{- if $s.nlb.acmCertArn }}
service.beta.kubernetes.io/aws-load-balancer-ssl-cert: {{ $s.nlb.acmCertArn | quote }}
service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
service.beta.kubernetes.io/aws-load-balancer-backend-protocol: ssl
service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy: {{ $s.nlb.sslPolicy }}
{{- end }}
{{- end }}
{{- end -}}
