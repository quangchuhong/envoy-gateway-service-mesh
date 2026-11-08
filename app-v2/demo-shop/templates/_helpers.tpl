{{- define "shop.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "shop.host" -}}
{{ .Values.hostPrefix }}.{{ .Values.domain }}
{{- end -}}

{{/*
  Deployment + Service + ServiceAccount + ConfigMap code cho một service Python.
  Tham số: dict "root" $ "name" <tên> "ns" <namespace> "file" <app/xxx.py> "replicas" N "env" <list env>
*/}}
{{- define "shop.pyService" -}}
{{- $r := .root -}}
{{- $code := $r.Files.Get .file -}}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .name }}
  namespace: {{ .ns }}
  labels:
    {{- include "shop.labels" $r | nindent 4 }}
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}-code
  namespace: {{ .ns }}
  labels:
    {{- include "shop.labels" $r | nindent 4 }}
data:
  {{ base .file }}: |-
{{ $code | indent 4 }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  namespace: {{ .ns }}
  labels:
    {{- include "shop.labels" $r | nindent 4 }}
    app: {{ .name }}
spec:
  replicas: {{ .replicas }}
  selector:
    matchLabels:
      app: {{ .name }}
  template:
    metadata:
      labels:
        app: {{ .name }}
      annotations:
        # Đổi code -> checksum đổi -> Pod được tạo lại
        checksum/code: {{ $code | sha256sum | trunc 16 }}
    spec:
      serviceAccountName: {{ .name }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: "{{ $r.Values.image.repository }}:{{ $r.Values.image.tag }}"
          imagePullPolicy: {{ $r.Values.image.pullPolicy }}
          command: ["python", "-u", "/app/{{ base .file }}"]
          env:
            - name: PORT
              value: "8080"
            - name: PYTHONDONTWRITEBYTECODE
              value: "1"
            {{- toYaml .env | nindent 12 }}
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
          resources:
            {{- toYaml $r.Values.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: code
              mountPath: /app
              readOnly: true
      volumes:
        - name: code
          configMap:
            name: {{ .name }}-code
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  namespace: {{ .ns }}
  labels:
    {{- include "shop.labels" $r | nindent 4 }}
spec:
  selector:
    app: {{ .name }}
  ports:
    - name: http
      port: 8080
      targetPort: http
{{- end -}}
