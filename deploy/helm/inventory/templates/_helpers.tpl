{{/* Common labels for every object in the chart. */}}
{{- define "inventory.labels" -}}
app.kubernetes.io/part-of: inventory
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* The GHCR image reference for a module. Usage: include "inventory.image" (dict "root" . "module" "inventory-server") */}}
{{- define "inventory.image" -}}
ghcr.io/{{ .root.Values.image.owner }}/inventory-root/{{ .module }}:{{ .root.Values.image.tag }}
{{- end }}
