/-
  E2E/Tests/NativeMetrics.lean - flared's native Prometheus /metrics endpoint

  Each flared serves its own /metrics (--metrics-server-port), replacing the
  operator's centralized stats re-export. The point of the design is fault-domain
  alignment: a node's metrics live and die with that node's pod, so an operator
  outage can no longer blank out every node's series at once (which used to make
  a collector failure indistinguishable from a real outage during triage).

  Scenarios covered:
    1. GET /metrics on a flared pod answers HTTP 200 with Prometheus text.
    2. memcached_current_items in /metrics equals `stats` curr_items exactly
       (values are re-emitted verbatim — no float round-trip).
    3. Writes are reflected: after N sets, memcached_current_items grows by N
       and memcached_commands_total{command="set"} is present.
    4. flared_version and the flare_node_rocksdb_* passthrough are exported.
    5. SPOF removal: with the OPERATOR scaled to 0, /metrics still answers —
       data-plane observability no longer shares the control plane's fate.

  Non-goals:
    - PodMonitor object creation (chart concern, not operator behaviour).
    - Prometheus server integration.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.NativeMetrics

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "native-metrics"
  «namespace» := "flare-native-metrics"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator-native-metrics"
  debugPod := "debug-native-metrics"
  storageBackend := "rocksdb"
}

private def metricsPort : Nat := 9150

/-- Fetch /metrics from a flared pod (by IP) via the debug pod. Returns the
    full HTTP response (status line + headers + body). -/
private def fetchMetrics (targetIp : String) : IO (Except String String) := do
  let cmd := s!"printf 'GET /metrics HTTP/1.0\\r\\n\\r\\n' | nc -w 5 {targetIp} {metricsPort}"
  execInDebugPod cfg.debugPod cfg.«namespace» cmd

/-- Extract the (verbatim) sample value of an unlabeled metric from a
    /metrics payload: the line `name <value>`. -/
private def sampleValue (payload name : String) : Option String :=
  payload.splitOn "\n" |>.map (·.trim.replace "\r" "") |>.findSome? fun line =>
    match line.splitOn " " with
    | [n, v] => if n == name then some v else none
    | _ => none

private def pod0 : String := s!"{cfg.name}-nodes-0"

def suite : TestSuite := {
  name := "native-metrics"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let ok ← waitForStable cfg 50
    if !ok then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  teardown := do
    cleanupCluster cfg
  tests := [
    { name := "GET /metrics answers HTTP 200 with Prometheus text"
      run := do
        let some ip ← getPodIp pod0 cfg.«namespace»
          | return .fail "pod IP unavailable"
        match ← fetchMetrics ip with
        | .error e => return .fail s!"fetch failed: {e}"
        | .ok payload =>
          if !containsSubstr payload "200 OK" then
            return .fail s!"expected HTTP 200; got: {payload.take 200}"
          else if !containsSubstr payload "# TYPE memcached_current_items gauge" then
            return .fail s!"missing TYPE header; got: {payload.take 400}"
          else return .pass },

    { name := "memcached_current_items equals stats curr_items verbatim"
      run := do
        let some ip ← getPodIp pod0 cfg.«namespace»
          | return .fail "pod IP unavailable"
        let statsItems ← getCurrItems cfg.debugPod cfg.«namespace» ip cfg.flarePort
        match ← fetchMetrics ip with
        | .error e => return .fail s!"fetch failed: {e}"
        | .ok payload =>
          match sampleValue payload "memcached_current_items" with
          | none => return .fail s!"no memcached_current_items sample; got: {payload.take 400}"
          | some v =>
            if v == toString statsItems then return .pass
            else return .fail s!"metrics={v} but stats curr_items={statsItems}" },

    { name := "writes are reflected in /metrics (curr_items grows, set counter present)"
      run := do
        let some ip ← getPodIp pod0 cfg.«namespace»
          | return .fail "pod IP unavailable"
        let before ← getCurrItems cfg.debugPod cfg.«namespace» ip cfg.flarePort
        for i in [0:5] do
          let ok ← memcachedSet cfg.debugPod cfg.«namespace» ip cfg.flarePort s!"nm{i}" s!"v{i}"
          if !ok then return .fail s!"set nm{i} failed"
        match ← fetchMetrics ip with
        | .error e => return .fail s!"fetch failed: {e}"
        | .ok payload =>
          match sampleValue payload "memcached_current_items" with
          | none => return .fail "no memcached_current_items sample"
          | some v =>
            if v.toNat?.getD 0 < before + 5 then
              return .fail s!"curr_items {v} < before({before})+5"
            else if !containsSubstr payload "memcached_commands_total{command=\"set\",status=\"hit\"}" then
              return .fail "missing set command counter"
            else return .pass },

    { name := "flared_version and rocksdb passthrough are exported"
      run := do
        let some ip ← getPodIp pod0 cfg.«namespace»
          | return .fail "pod IP unavailable"
        match ← fetchMetrics ip with
        | .error e => return .fail s!"fetch failed: {e}"
        | .ok payload =>
          if !containsSubstr payload "flared_version{version=" then
            return .fail "missing flared_version"
          else if !containsSubstr payload "flare_node_rocksdb_" then
            return .fail "missing flare_node_rocksdb_* passthrough"
          else return .pass },

    -- The design goal itself: metrics survive a control-plane outage.
    { name := "/metrics still answers with the operator scaled to 0 (SPOF removed)"
      run := do
        let some ip ← getPodIp pod0 cfg.«namespace»
          | return .fail "pod IP unavailable"
        let _ ← kubectlScale "deployment" cfg.operatorName cfg.«namespace» 0
        let _ ← kubectl ["wait", "--for=delete", "pod",
                         "-l", s!"app={cfg.operatorName}",
                         "-n", cfg.«namespace», "--timeout=120s"]
        let result ← fetchMetrics ip
        -- restore the operator before judging, so teardown/later suites see a
        -- healthy control plane even if the assertion fails
        let _ ← kubectlScale "deployment" cfg.operatorName cfg.«namespace» 1
        match result with
        | .error e => return .fail s!"fetch with operator down failed: {e}"
        | .ok payload =>
          if containsSubstr payload "200 OK"
             && (sampleValue payload "memcached_current_items").isSome then
            return .pass
          else return .fail s!"metrics degraded with operator down: {payload.take 300}" }
  ]
}

end FlareOperator.E2E.Tests.NativeMetrics
