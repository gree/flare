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
app.kubernetes.io/component: operator
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
Well-known (recommended) labels for the DATA-plane / backup / analysis
workloads, which otherwise carry only the legacy `app` label. The `app` label
stays because the operator's pod selector, the STS matchLabels and the
Monitor/PDB selectors depend on it (immutable), so these are ADDED alongside,
not a replacement. Call with (dict "root" $ "name" "flared" "component" "node").
*/}}
{{- define "flare-operator.wellKnown" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
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

{{/*
Memory quantity -> whole MiB ("" when the form is not understood, e.g. "1.5Gi").
Accepts Gi, Mi, Ki, G, M and plain bytes.
*/}}
{{- define "flare-operator.memMiB" -}}
{{- $q := toString . -}}
{{- if regexMatch "^[0-9]+Gi$" $q -}}{{ mul (trimSuffix "Gi" $q | atoi) 1024 }}
{{- else if regexMatch "^[0-9]+Mi$" $q -}}{{ trimSuffix "Mi" $q | atoi }}
{{- else if regexMatch "^[0-9]+Ki$" $q -}}{{ div (trimSuffix "Ki" $q | atoi) 1024 }}
{{- else if regexMatch "^[0-9]+G$" $q -}}{{ div (mul (trimSuffix "G" $q | atoi) 1000000000) 1048576 }}
{{- else if regexMatch "^[0-9]+M$" $q -}}{{ div (mul (trimSuffix "M" $q | atoi) 1000000) 1048576 }}
{{- else if regexMatch "^[0-9]+$" $q -}}{{ div (atoi $q) 1048576 }}
{{- end -}}
{{- end -}}

{{/*
RocksDB memory FLOOR of one flared process, in MiB: block cache plus
2 column families (default + replication meta) x write buffer size x number
of write buffers. flared's defaults apply to unset fields (512 / 64 / 3).
A floor, not an RSS bound: compaction, replication, allocator overhead and
tmpfs data come on top (docs/reports/2026-09-27-memory-config.md).
*/}}
{{- define "flare-operator.rocksdbFloorMiB" -}}
{{- $r := .Values.cluster.rocksdb | default dict -}}
{{- $bc := 512 -}}{{- if hasKey $r "blockCacheSizeMb" -}}{{- $bc = int $r.blockCacheSizeMb -}}{{- end -}}
{{- $wb := 64 -}}{{- if hasKey $r "writeBufferSizeMb" -}}{{- $wb = int $r.writeBufferSizeMb -}}{{- end -}}
{{- $n := 3 -}}{{- if hasKey $r "maxWriteBufferNumber" -}}{{- $n = int $r.maxWriteBufferNumber -}}{{- end -}}
{{- add $bc (mul 2 $wb $n) -}}
{{- end -}}

{{/*
Memory budget check for the flared container. Fails the render when the
RocksDB floor alone reaches the memory limit (the pod can only OOM), and
returns a warning string when the floor is above 70% of the limit or, on
tmpfs, floor + tmpfs.sizeLimit exceeds it. Empty when nothing to say or the
limit is not set / not understood.
*/}}
{{- define "flare-operator.memoryBudgetWarning" -}}
{{- $c := .Values.cluster -}}
{{- if and $c.enabled (eq (toString $c.storageBackend) "rocksdb") -}}
{{- $limitQ := "" -}}
{{- if and $c.resources $c.resources.limits $c.resources.limits.memory -}}{{- $limitQ = $c.resources.limits.memory -}}{{- end -}}
{{- $limit := include "flare-operator.memMiB" $limitQ | default "0" | atoi -}}
{{- $floor := include "flare-operator.rocksdbFloorMiB" . | atoi -}}
{{- if gt $limit 0 -}}
{{- if ge $floor $limit -}}
{{- fail (printf "cluster.resources.limits.memory (%s = %d MiB) is at or below the RocksDB memory floor of %d MiB (block cache + 2 column families x write buffer x buffers): flared can only be OOM-killed. Raise the limit or lower cluster.rocksdb budgets." (toString $limitQ) $limit $floor) -}}
{{- end -}}
{{- $tmpfs := 0 -}}
{{- if and $c.tmpfs $c.tmpfs.enabled $c.tmpfs.sizeLimit -}}{{- $tmpfs = include "flare-operator.memMiB" $c.tmpfs.sizeLimit | default "0" | atoi -}}{{- end -}}
{{- if gt (mul $floor 10) (mul $limit 7) -}}
WARNING: the RocksDB memory floor ({{ $floor }} MiB) is above 70% of the flared memory limit ({{ $limit }} MiB); compaction, replication and allocator overhead come on top.
{{- end -}}
{{- if and (gt $tmpfs 0) (gt (add $floor $tmpfs) $limit) }}
WARNING: on tmpfs the data counts against the pod's memory: RocksDB floor {{ $floor }} MiB + tmpfs.sizeLimit {{ $tmpfs }} MiB exceeds the memory limit {{ $limit }} MiB; a full tmpfs would OOM the pod.
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
