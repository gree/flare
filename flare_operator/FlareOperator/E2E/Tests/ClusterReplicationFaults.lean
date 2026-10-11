/-
  Cross-cluster forwarding under faults: no write the source acknowledged may
  be lost WITHOUT being counted.

  Audit 2026-10-11 (docs/review-cross-cluster-2026-10-11.md): the live
  cross-cluster stream is best effort — a forward that fails is counted in
  `proxy_write_dropped[dest]` on the source master and NOT repaired. Two paths
  were not even counted: the forwarding thread that could not connect at
  start returned and left the pool while the replication stayed 'started',
  and every later forward then failed to enqueue ("no available thread",
  a log_notice). A destination whose name does not resolve when replication
  is enabled (a Service created a moment later, a DNS hiccup at pod start)
  silently lost every forward until a restart or a disable/enable.

  These tests require, per key the source acknowledged: it is on the
  destination, or the drop counter moved by at least that many. They do NOT
  claim repair — a counted drop stays a divergence (runbook: re-seed).
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ClusterReplicationFaults

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfgSrc : ClusterConfig := {
  name := "crf-src"
  «namespace» := "flare-crf-src"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-crf-src"
  debugPod := "debug-crf"
  storageBackend := "rocksdb"
}

private def cfgDst : ClusterConfig := {
  name := "crf-dst"
  «namespace» := "flare-crf-dst"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-crf-dst"
  debugPod := "debug-crf"
  storageBackend := "rocksdb"
}

/-- A Service that does NOT exist when replication is enabled. -/
private def lateSvcName : String := "crf-late"
private def lateSvc : String := s!"{lateSvcName}.{cfgDst.«namespace»}.svc.cluster.local"

private def lateServiceYaml : String :=
  s!"apiVersion: v1
kind: Service
metadata:
  name: {lateSvcName}
  namespace: {cfgDst.«namespace»}
spec:
  selector:
    app: flare
    cluster: {cfgDst.name}
  ports:
  - port: {cfgDst.flarePort}
    targetPort: {cfgDst.flarePort}
"

private def applyService : IO (Except String Unit) := do
  let out ← IO.Process.output { cmd := "sh", args := #["-c", s!"cat <<'ENDOFYAML' | kubectl apply -f -\n{lateServiceYaml}\nENDOFYAML"] }
  if out.exitCode == 0 then return .ok () else return .error out.stderr

private def masterIp (cfg : ClusterConfig) : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  match findMasterPod (parseNodeSync sync) 0 with
  | none => return none
  | some m => getPodIp m cfg.«namespace»

private def droppedTotal (ip : String) : IO (Option Nat) := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfgSrc.flarePort}"
  match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» cmd with
  | .error _ => return none
  | .ok out =>
    return (out.splitOn "\n").findSome? fun l =>
      let t := (l.trim.replace "\r" "")
      if t.startsWith "STAT proxy_write_dropped " then (t.drop "STAT proxy_write_dropped ".length).trim.toNat?
      else none

private def writeKeys (ip pfx : String) (n : Nat) : IO Nat := do
  let mut ok := 0
  for i in List.range n do
    if ← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» ip cfgSrc.flarePort s!"{pfx}_{i}" s!"v_{i}" then
      ok := ok + 1
  return ok

private def presentOn (ip pfx : String) (n : Nat) : IO Nat := do
  let mut present := 0
  for i in List.range n do
    if (← memcachedGet cfgDst.debugPod cfgDst.«namespace» ip cfgDst.flarePort s!"{pfx}_{i}") == some s!"v_{i}" then
      present := present + 1
  return present

private def earlyKeys : Nat := 10
private def lateKeys : Nat := 20

def suite : TestSuite := {
  name := "cluster-replication-faults"
  setup := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
    discard <| kubectl ["delete", "service", lateSvcName, "-n", cfgDst.«namespace», "--ignore-not-found"]
    deployCluster cfgSrc
    let s1 ← waitForStable cfgSrc 50
    if !s1 then throw (IO.userError "source cluster did not stabilize")
    deploySecondCluster cfgDst
    let s2 ← waitForStable cfgDst 50
    if !s2 then throw (IO.userError "destination cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfgSrc.«namespace» s!"app={cfgSrc.operatorName}"
  teardown := do
    discard <| kubectl ["delete", "service", lateSvcName, "-n", cfgDst.«namespace», "--ignore-not-found"]
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
  tests := [
    { name := "the destination name does not resolve when replication is enabled: every acknowledged write is on the destination or counted as dropped; once the name resolves, later writes arrive (the forwarding thread did not leave)"
      run := do
        let patchJson := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{lateSvc}\",\"port\":{cfgDst.flarePort},\"mode\":\"duplicate\",\"concurrency\":1}}}"
        match ← kubectlPatch "flarecluster" cfgSrc.name cfgSrc.«namespace» patchJson with
        | .error e => return .fail s!"could not enable replication: {e}"
        | .ok _ => pure ()
        -- the forwarding thread must have TRIED and failed (the name does
        -- not resolve yet), else the window was never opened
        let tried ← waitForCondition "the source tried to connect to the unresolvable destination" 240 do
          let l ← kubectlLogsLabel s!"app=flare,cluster={cfgSrc.name}" cfgSrc.«namespace» 3000
          return containsSubstr l "failed to connect to cluster replication destination server"
        if !tried then return .fail s!"no failed connect to {lateSvc} was logged: the unresolvable-at-start case was not exercised"
        match ← masterIp cfgSrc with
        | none => return .fail "no source master"
        | some sIp =>
          let d0 := (← droppedTotal sIp).getD 0
          let wroteEarly ← writeKeys sIp "early" earlyKeys
          IO.sleep 20000
          let d1 := (← droppedTotal sIp).getD 0
          match ← applyService with
          | .error e => return .fail s!"could not create {lateSvcName}: {e}"
          | .ok _ => pure ()
          let resolvable ← waitForCondition s!"{lateSvc} resolves from the source" 120 do
            match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» s!"nslookup {lateSvc} >/dev/null 2>&1 && echo ok || echo no" with
            | .ok o => return containsSubstr o "ok"
            | .error _ => return false
          if !resolvable then return .fail s!"{lateSvc} never resolved"
          let wroteLate ← writeKeys sIp "late" lateKeys
          match ← masterIp cfgDst with
          | none => return .fail "no destination master"
          | some dIp =>
            let _ ← waitForCondition s!"all {lateKeys} later keys on the destination" 120 do
              return (← presentOn dIp "late" lateKeys) == lateKeys
            let late ← presentOn dIp "late" lateKeys
            let early ← presentOn dIp "early" earlyKeys
            let d2 := (← droppedTotal sIp).getD 0
            IO.eprintln s!"# acknowledged: early {wroteEarly}/{earlyKeys}, late {wroteLate}/{lateKeys}; on the destination: early {early}, late {late}; proxy_write_dropped {d0} → {d1} (unresolvable) → {d2}"
            if wroteEarly != earlyKeys || wroteLate != lateKeys then
              return .fail "the source did not acknowledge every write — the premise (acknowledged writes) does not hold"
            -- every early key: arrived or counted
            if early + (d1 - d0) < earlyKeys then
              return .fail s!"SILENT LOSS: {earlyKeys - early} early writes are neither on the destination nor counted (drops +{d1 - d0}) — the operator cannot see them"
            if late < lateKeys then
              return .fail s!"after the name resolved only {late}/{lateKeys} writes reached the destination (drops now {d2}): the forwarding stayed broken"
            return .pass }
  ]
}

end FlareOperator.E2E.Tests.ClusterReplicationFaults
