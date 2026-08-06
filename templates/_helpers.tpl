{{/*
Copyright (c) 2026 The Kata Containers Authors
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "kata-lifecycle-manager.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kata-lifecycle-manager.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kata-lifecycle-manager.labels" -}}
helm.sh/chart: {{ include "kata-lifecycle-manager.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "kata-lifecycle-manager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kata-containers
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "kata-lifecycle-manager.serviceAccountName" -}}
{{- include "kata-lifecycle-manager.fullname" . }}
{{- end }}

{{/*
Bash that writes /tmp/kata-deploy-tolerations.yaml: the kata-deploy release's own
tolerations plus the cordon taint. Used by every job-mode helm upgrade.

Job mode installs through a dispatcher hook Job. The per-node install Jobs it
fans out carry a nodeName and bypass the scheduler, but the dispatcher pod itself
is scheduled normally and kata-deploy renders it with the release's tolerations
only. Every node of a wave is cordoned before the upgrade runs, so wherever the
wave covers all schedulable nodes the dispatcher would sit Pending on
FailedScheduling and block the upgrade until the release timeout. Tolerating the
cordon taint mirrors what the dispatcher already assumes when it picks nodes to
install on, and what the DaemonSet controller does implicitly in daemonset mode.

Expects $RELEASE and $NS to be set, and jq to be available.
*/}}
{{- define "kata-lifecycle-manager.dispatcherTolerationSnippet" -}}
helm get values "$RELEASE" -n "$NS" -o json 2>/dev/null \
  | jq -s '.[0] // {}' > /tmp/kata-deploy-values.json
jq '{tolerations: ((.tolerations // []) + [{
       key: "node.kubernetes.io/unschedulable",
       operator: "Exists",
       effect: "NoSchedule"
     }] | unique)}' \
  /tmp/kata-deploy-values.json > /tmp/kata-deploy-tolerations.yaml
{{- end }}
