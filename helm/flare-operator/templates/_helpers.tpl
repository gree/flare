{{/*
Expand the name of the chart.
*/}}
{{- define "flare-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "flare-operator.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "flare-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "flare-operator.labels" -}}
helm.sh/chart: {{ include "flare-operator.chart" . }}
{{ include "flare-operator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "flare-operator.clusterLabel" . }}
{{- end }}

{{/*
Cluster-tracking label. Uniform key stamped on EVERY resource (control plane
via `labels`, data plane + backup explicitly) so "all resources of cluster X"
is one selector regardless of release name — the primitive that makes several
independently-released operators/clusters coexist in one namespace. Distinct
from the data plane's functional `cluster=<name>` label (which the operator's
pod selector depends on and must not change); this is for humans/tooling.
*/}}
{{- define "flare-operator.clusterLabel" -}}
app.kubernetes.io/part-of: flare
flare.gree.net/cluster: {{ .Values.clusterName }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "flare-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "flare-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "flare-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "flare-operator.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the image name
*/}}
{{- define "flare-operator.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}
