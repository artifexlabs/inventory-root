{{/* Common labels for every object in the chart. */}}
{{- define "inventory.labels" -}}
app.kubernetes.io/part-of: inventory
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* The Docker Hub image reference for a module. Usage: include "inventory.image" (dict "root" . "module" "inventory-server") */}}
{{- define "inventory.image" -}}
{{ .root.Values.image.registry }}/{{ .module }}:{{ .root.Values.image.tag }}
{{- end }}
