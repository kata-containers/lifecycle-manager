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

Expects $RELEASE and $NS to be set, and jq to be available. The tolerations are
taken from the current release values unless $TOLERATION_BASE_VALUES points at
a values file to read them from instead (the rollback paths do that, so they
restore the tolerations of the revision they roll back to).
*/}}
{{- define "kata-lifecycle-manager.dispatcherTolerationSnippet" -}}
if [ -z "${TOLERATION_BASE_VALUES:-}" ]; then
  helm get values "$RELEASE" -n "$NS" -o json 2>/dev/null \
    | jq -s '.[0] // {}' > /tmp/kata-deploy-values.json
  TOLERATION_BASE_VALUES=/tmp/kata-deploy-values.json
fi
jq '{tolerations: ((.tolerations // []) + [{
       key: "node.kubernetes.io/unschedulable",
       operator: "Exists",
       effect: "NoSchedule"
     }] | unique)}' \
  "$TOLERATION_BASE_VALUES" > /tmp/kata-deploy-tolerations.yaml
{{- end }}

{{/*
Bash that fills ROLLBACK_VALUES_ARGS with the helm flags that put the release
back on the values it ran with under $ROLLBACK_TARGET_VERSION. Used by the
job-mode rollback paths, where helm rollback cannot be used because it does not
re-run the kata-deploy dispatcher.

A rollback goes back to an older chart, so it has to go back to the older
values too. Carrying the current ones over would leave the reverted upgrade's
overrides in place, and an image built for the newer chart on top of the older
chart's templates is not a combination kata-deploy supports: the image expects
mounts and a security context the older chart does not render, and the pod
crash-loops. When no past revision ran that chart version there is nothing to
restore, so the current values are kept and the mismatch is called out instead.

Expects $RELEASE, $NS and $ROLLBACK_TARGET_VERSION to be set, and jq to be
available.
*/}}
{{- define "kata-lifecycle-manager.rollbackValuesSnippet" -}}
ROLLBACK_REVISION=$(helm history "$RELEASE" -n "$NS" --max 256 -o json 2>/dev/null \
  | jq -r --arg v "$ROLLBACK_TARGET_VERSION" \
    '[.[] | select((.chart | ltrimstr("kata-deploy-")) == $v)]
     | max_by(.revision) | .revision // empty')
if [ -n "$ROLLBACK_REVISION" ]; then
  helm get values "$RELEASE" -n "$NS" --revision "$ROLLBACK_REVISION" -o json 2>/dev/null \
    | jq -s '.[0] // {}' > /tmp/kata-deploy-rollback-values.yaml
  ROLLBACK_VALUES_ARGS=(--reset-values -f /tmp/kata-deploy-rollback-values.yaml)
  TOLERATION_BASE_VALUES=/tmp/kata-deploy-rollback-values.yaml
  echo "Restoring the values of revision $ROLLBACK_REVISION (chart $ROLLBACK_TARGET_VERSION)"
else
  ROLLBACK_VALUES_ARGS=(--reset-then-reuse-values)
  echo "WARNING: no revision of this release ran chart $ROLLBACK_TARGET_VERSION, so the"
  echo "         current values are kept. Check that they fit that chart, in"
  echo "         particular any pinned image."
fi
{{- end }}
