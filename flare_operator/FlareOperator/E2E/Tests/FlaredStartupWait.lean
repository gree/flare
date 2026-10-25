/-
  E2E/Tests/FlaredStartupWait.lean - flared's bounded wait for the index server at startup

  The general Setup waits until the operator leads before it starts flared, so
  no other suite starts flared before the index exists. This suite alone skips
  that wait (`skipLeaderWait`): a fresh cluster's operator and flared start
  together, the operator leads only after its Lease absence wait (about
  18-23 s), and flared must wait for the index instead of exiting.

  1. flared starts before the index exists: it logs the bounded wait, registers
     once the index serves, becomes Ready, and its container is the same one
     (same containerID, restartCount 0) — no restart was needed.
  2. control: with the operator scaled to 0 the index never comes; a new flared
     pod waits and gives up by itself at the end of its 30 s budget (log
     "gave up after X ms of a 30000 ms startup wait", X in [30 s, 33.5 s]), its
     container exits on its own (exit code not 137) and ran well under the
     startupProbe's earliest kill (85 s from container start): the restart comes
     from the deadline, not from a probe.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.FlaredStartupWait

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "fsw"
  «namespace» := "flare-fsw"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator"
  debugPod := "debug-fsw"
  skipLeaderWait := true
}

private def ns : String := cfg.«namespace»
private def pod : String := s!"{cfg.name}-nodes-0"

private def jp (path : String) : IO String := do
  match ← kubectl ["get", "pod", pod, "-n", ns, "-o", s!"jsonpath={path}"] with
  | .ok v => return v.trim
  | .error _ => return ""

private def restartCount : IO Nat := return (← jp "{.status.containerStatuses[0].restartCount}").toNat?.getD 0
private def containerId : IO String := jp "{.status.containerStatuses[0].containerID}"
private def ready : IO Bool := return (← jp "{.status.conditions[?(@.type==\"Ready\")].status}") == "True"

/-- "2026-10-25T06:07:34Z" as epoch seconds (UTC). -/
private def epochS (s : String) : Option Int :=
  match s.trim.splitOn "T" with
  | [d, t] =>
    match d.splitOn "-", (t.dropRightWhile (· == 'Z')).splitOn ":" with
    | [y, mo, da], [h, mi, se] =>
      match y.toInt?, mo.toInt?, da.toInt?, h.toInt?, mi.toInt?, ((se.splitOn ".").head!).toInt? with
      | some y, some mo, some da, some h, some mi, some se =>
        let yy := if mo ≤ 2 then y - 1 else y
        let era := (if yy ≥ 0 then yy else yy - 399) / 400
        let yoe := yy - era * 400
        let doy := (153 * (if mo > 2 then mo - 3 else mo + 9) + 2) / 5 + da - 1
        let doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
        some ((era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se)
      | _, _, _, _, _, _ => none
    | _, _ => none
  | _ => none

/-- The number in "gave up after <n> ms". -/
private def gaveUpMs (log : String) : Option Nat :=
  match log.splitOn "gave up after " with
  | _ :: rest :: _ => (rest.takeWhile Char.isDigit).toNat?
  | _ => none

def suite : TestSuite := {
  name := "flared-startup-wait"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
  onFailure := dumpClusterDiagnostics ns s!"app={cfg.operatorName}"
  teardown := cleanupCluster cfg
  tests := [
    { name := "(bounded wait) flared started before the index exists waits for it, registers when it serves and becomes Ready in the same container (restartCount 0, same containerID)"
      run := do
        let started ← waitForCondition s!"{pod}'s flared container started" 120 do
          return !(← containerId).isEmpty
        if !started then return .fail s!"{pod}'s container did not start within 120 s"
        let cid0 ← containerId
        let r0 ← restartCount
        let isReady ← waitForCondition s!"{pod} Ready (registered with the operator's index)" 180 do ready
        let cid1 ← containerId
        let r1 ← restartCount
        let log ← kubectlLogs pod ns 2000
        let waits := (log.splitOn "index server not reachable yet").length - 1
        let registered := containsSubstr log "meta data from index server"
        IO.eprintln s!"# {pod}: container {cid0} -> {cid1}, restartCount {r0} -> {r1}, wait lines {waits}, registered {registered}, Ready {isReady}"
        if waits == 0 then
          return .fail "PRECONDITION NOT MET: flared never waited (the index existed when it started); the bounded wait was not exercised"
        if !isReady then return .fail s!"{pod} did not become Ready within 180 s after waiting for the index"
        if !registered then return .fail s!"{pod} became Ready without logging its registration with the index"
        if r1 != 0 || r0 != 0 then return .fail s!"{pod}'s container restarted ({r0} -> {r1}): the wait did not keep the process alive"
        if cid1 != cid0 then return .fail s!"{pod}'s container changed ({cid0} -> {cid1})"
        return .pass },

    { name := "(control: no index) with the operator scaled to 0 a new flared waits its 30 s budget, gives up by itself and exits (not 137), well before the startupProbe's earliest kill (85 s)"
      run := do
        discard <| kubectl ["scale", s!"deployment/{cfg.operatorName}", "-n", ns, "--replicas=0"]
        let gone ← waitForCondition "no operator pod" 120 do
          return (← getPodNames s!"app={cfg.operatorName}" ns).isEmpty
        if !gone then return .fail "the operator pods did not go away after scaling to 0"
        discard <| kubectl ["delete", "pod", pod, "-n", ns, "--wait=true"]
        let started ← waitForCondition s!"the new {pod} container started" 120 do
          return !(← containerId).isEmpty
        if !started then return .fail s!"the new {pod} container did not start"
        let exited ← waitForCondition s!"{pod}'s flared gave up and exited (restartCount >= 1)" 150 do
          return (← restartCount) ≥ 1
        let prev ← match ← kubectl ["logs", pod, "-n", ns, "--previous", "--tail=2000"] with
          | .ok v => pure v
          | .error _ => pure ""
        let code := (← jp "{.status.containerStatuses[0].lastState.terminated.exitCode}")
        let reason := (← jp "{.status.containerStatuses[0].lastState.terminated.reason}")
        let st := epochS (← jp "{.status.containerStatuses[0].lastState.terminated.startedAt}")
        let fi := epochS (← jp "{.status.containerStatuses[0].lastState.terminated.finishedAt}")
        let ran := match st, fi with
          | some a, some b => some (b - a)
          | _, _ => none
        let waits := (prev.splitOn "index server not reachable yet").length - 1
        let g := gaveUpMs prev
        IO.eprintln s!"# control: exited {exited}; previous container: wait lines {waits}, gave up after {g} ms; terminated exitCode {code} reason {reason}, ran {ran} s"
        -- restore the operator for a clean teardown
        discard <| kubectl ["scale", s!"deployment/{cfg.operatorName}", "-n", ns, "--replicas=1"]
        if !exited then return .fail s!"{pod}'s flared did not exit within 150 s without an index"
        if waits == 0 then return .fail "the previous container logged no bounded wait"
        match g with
        | none => return .fail "the previous container did not log 'gave up after ... ms of a ... ms startup wait'"
        | some ms =>
          if ms < 30000 || ms > 33500 then return .fail s!"flared gave up after {ms} ms, not at its 30 s budget (+ one connect attempt)"
        if code == "137" then return .fail "the container was killed (137), not exited by its own deadline"
        match ran with
        | none => return .fail "no start/finish time of the terminated container"
        | some r =>
          if r < 30 || r ≥ 80 then return .fail s!"the terminated container ran {r} s: expected about the 30 s budget plus startup, below the startupProbe's earliest kill (85 s)"
        return .pass }
  ] }

end FlareOperator.E2E.Tests.FlaredStartupWait
