/-
  E2E/Tests/LeaseFailClosed.lean - the leader's lease deadline is fail-closed

  Two operator replicas (a leader and a standby; the index Service selects the
  `role=leader` pod). The leader's lease guard (StateMachine/LeaseGuard) keeps a
  LOCAL deadline heldUntil = send + 15 s - 3 s of its last positively confirmed
  renew; when it passes without a newer confirmation the leader stops serving
  index traffic, drops health leader, labels itself standby and exits.

  1. control: no stall, reconcile passes stretched to 16 s (test seam
     FLARE_TEST_RECONCILE_PASS_DELAY_FILE) for 4 minutes: no step-down, no
     restart, same holder, same generation (a spurious fail-closed would be a
     regression of the renewer).
  2. stall: the leader's lease API hangs (test seam FLARE_TEST_LEASE_API_STALL_FILE:
     while the file exists every lease API call of THAT pod hangs until its
     bound), reconcile passes stretched as in 1 (the stalled reconcile + stalled
     renewer of the review). Required, from timestamps:
       - the old leader logs LEASE FAIL-CLOSED no later than S + 12 s + watchdog
         (S: the stall begins) and never earlier than S + 5 s (it waited for
         the deadline, it did not step down at the first error);
       - the last index request the old leader received is NOT after its
         FAIL-CLOSED line;
       - the standby acquires only after (its acquire is logged at least 1 s
         after the old leader's FAIL-CLOSED line; the lease generation +1);
       - from the moment the standby holds the lease the index Service never
         routes to the old pod (its address is absent from the Service's
         endpoints in every sample from 3 s on: the endpoints controller is
         asynchronous, the old pod has already stopped answering).
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.LeaseFailClosed

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "lease-fc"
  «namespace» := "flare-lease-fc"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator"
  debugPod := "debug-lease-fc"
  operatorReplicas := 2
  operatorEnv := [("FLARE_TEST_LEASE_API_STALL_FILE", "/tmp/lease-stall"),
                  ("FLARE_TEST_RECONCILE_PASS_DELAY_FILE", "/tmp/slow-pass")]
}

private def ns : String := cfg.«namespace»
private def leaseName : String := s!"{cfg.name}-operator-lease"

/-! ## time -/

/-- Days since 1970-01-01 of a civil date. -/
private def daysFromCivil (y0 m d : Int) : Int :=
  let y := if m ≤ 2 then y0 - 1 else y0
  let era := (if y ≥ 0 then y else y - 399) / 400
  let yoe := y - era * 400
  let doy := (153 * (if m > 2 then m - 3 else m + 9) + 2) / 5 + d - 1
  let doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

/-- "2026-10-24T12:00:00.123456789Z" (RFC 3339, UTC) as epoch milliseconds. -/
private def parseTs (s : String) : Option Int :=
  match s.trim.splitOn "T" with
  | [date, time] =>
    let time := (time.dropRightWhile (· == 'Z'))
    match date.splitOn "-", time.splitOn ":" with
    | [y, mo, d], [h, mi, secFrac] =>
      let (sec, frac) := match secFrac.splitOn "." with
        | [a, b] => (a, b)
        | _ => (secFrac, "")
      let ms := (frac ++ "000").take 3
      match y.toInt?, mo.toInt?, d.toInt?, h.toInt?, mi.toInt?, sec.toInt?, ms.toInt? with
      | some y, some mo, some d, some h, some mi, some sec, some ms =>
        some (((daysFromCivil y mo d * 24 + h) * 60 + mi) * 60000 + sec * 1000 + ms)
      | _, _, _, _, _, _, _ => none
    | _, _ => none
  | _ => none

private def wallMs : IO Int := do
  let r ← IO.Process.output { cmd := "date", args := #["+%s%3N"] }
  return r.stdout.trim.toInt?.getD 0

/-- Timestamped log lines of one pod as (ms, line). `previous`: the previous container. -/
private def podLog (pod : String) (previous : Bool) : IO (List (Int × String)) := do
  let args := ["logs", "-n", ns, pod, "--timestamps", "--tail=-1"] ++ (if previous then ["--previous"] else [])
  match ← kubectl args with
  | .error _ => return []
  | .ok out =>
    return out.splitOn "\n" |>.filterMap fun l =>
      match l.splitOn " " with
      | ts :: rest => (parseTs ts).map fun t => (t, " ".intercalate rest)
      | _ => none

/-! ## cluster facts -/

private def operatorPods : IO (List String) := getPodNames s!"app={cfg.operatorName}" ns

private def leaseField (path : String) : IO String := do
  match ← kubectlGetJsonpath "lease" leaseName ns path with
  | .ok v => return v.trim
  | .error _ => return ""

private def holder : IO String := leaseField "{.spec.holderIdentity}"
private def transitions : IO Nat := return (← leaseField "{.spec.leaseTransitions}").toNat?.getD 0

private def restarts (pod : String) : IO Nat := do
  match ← kubectl ["get", "pod", pod, "-n", ns, "-o", "jsonpath={.status.containerStatuses[0].restartCount}"] with
  | .ok v => return v.trim.toNat?.getD 0
  | .error _ => return 0

private def endpointIps : IO (List String) := do
  match ← kubectl ["get", "endpoints", cfg.operatorName, "-n", ns, "-o",
                   "jsonpath={.subsets[*].addresses[*].ip}"] with
  | .ok v => return (v.trim.splitOn " ").filter (· != "")
  | .error _ => return []

private def execIn (pod cmd : String) : IO (Except String String) :=
  kubectl ["exec", "-n", ns, pod, "-c", "flare-operator", "--", "sh", "-c", cmd]

private def indexRequest : IO String :=
  operatorTcpCmd cfg.debugPod ns cfg.operatorName cfg.operatorPort "meta"

/-- The pod carrying role=leader that also holds the lease, once both agree. -/
private def waitLeader : IO (Option String) := do
  let found ← IO.mkRef (none : Option String)
  let _ ← waitForCondition "an operator pod holds the lease and carries role=leader" 180 do
    let h ← holder
    if h.isEmpty then return false
    match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app={cfg.operatorName},flare.gree.net/role=leader",
                     "-o", "jsonpath={.items[*].metadata.name}"] with
    | .ok v =>
      if v.trim == h then
        found.set (some h)
        return true
      else return false
    | .error _ => return false
  found.get

def suite : TestSuite := {
  name := "operator-lease-failclosed"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    if !(← waitForStable cfg 50) then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics ns s!"app={cfg.operatorName}"
  teardown := cleanupCluster cfg
  tests := [
    { name := "(control) 16 s reconcile passes for 4 minutes with a healthy lease API: no fail-closed step-down, no restart, same holder and generation"
      run := do
        let some leader ← waitLeader | return .fail "no operator pod holds the lease with role=leader within 180 s"
        let pods ← operatorPods
        if pods.length != 2 then return .fail s!"expected 2 operator pods, got {pods}"
        let t0 ← transitions
        let r0 ← pods.mapM restarts
        match ← execIn leader "echo 16 > /tmp/slow-pass" with
        | .error e => return .fail s!"could not stretch the leader's passes: {e}"
        | .ok _ => pure ()
        let start ← wallMs
        let mut bad : Option String := none
        while (← wallMs) - start < 240000 && bad.isNone do
          IO.sleep 10000
          let h ← holder
          if h != leader then bad := some s!"the holder changed from {leader} to '{h}'"
          let tr ← transitions
          if tr != t0 then bad := some s!"the lease generation moved {t0} -> {tr}"
        if let some b := bad then return .fail s!"spurious loss of leadership during the control: {b}"
        let r1 ← pods.mapM restarts
        if r1 != r0 then return .fail s!"an operator container restarted during the control: {r0} -> {r1}"
        let mut slow := false
        for pod in pods do
          for (_, l) in ← podLog pod false do
            if containsSubstr l "LEASE FAIL-CLOSED" || containsSubstr l "LOST LEASE" then
              return .fail s!"{pod} stepped down without a stall: {l.take 200}"
            if containsSubstr l "reconcile slow: 1" then
              let n := ((l.splitOn "reconcile slow: ").getD 1 "").takeWhile Char.isDigit
              if n.toNat?.getD 0 ≥ 15000 then slow := true
        if !slow then
          return .fail "no reconcile pass of 15 s or more was logged: the control did not exercise the long passes"
        discard <| execIn leader "rm -f /tmp/slow-pass"
        return .pass },

    { name := "(stall) the leader's lease API hangs (stretched passes too): it stops serving, drops leader health and exits no later than its local deadline; the standby acquires only after; the index Service never routes to the old pod once the new one holds the lease"
      run := do
        let some old ← waitLeader | return .fail "no operator pod holds the lease with role=leader within 180 s"
        let pods ← operatorPods
        let some standby := pods.find? (· != old) | return .fail s!"no standby among {pods}"
        let t0 ← transitions
        let some oldIp ← getPodIp old ns | return .fail s!"no address of {old}"
        let rOld ← restarts old
        if (← indexRequest).trim.isEmpty then return .fail "the leader does not answer an index request before the stall"
        match ← execIn old "echo 16 > /tmp/slow-pass" with
        | .error e => return .fail s!"could not stretch the passes: {e}"
        | .ok _ => pure ()
        IO.sleep 20000  -- at least one stretched pass in flight
        let s0 ← wallMs
        match ← execIn old "touch /tmp/lease-stall" with
        | .error e => return .fail s!"could not stall the lease API of {old}: {e}"
        | .ok _ => pure ()
        let s1 ← wallMs
        IO.eprintln s!"# lease API of {old} stalled at {s0}..{s1} (holder {old}, generation {t0}, standby {standby})"
        -- sample: lease holder, Service endpoints, an index request (to leave a served-request trail)
        let mut samples : List (Int × String × List String) := []
        let mut newSince : Option Int := none
        let begin_ ← wallMs
        while (← wallMs) - begin_ < 150000 && !(newSince.isSome && (← wallMs) - newSince.getD 0 > 12000) do
          let t ← wallMs
          let h ← holder
          let eps ← endpointIps
          samples := samples ++ [(t, h, eps)]
          if h == standby && newSince.isNone then newSince := some t
          discard indexRequest
          IO.sleep 500
        let some th := newSince | return .fail s!"the standby {standby} never took the lease within 150 s of the stall (holder: {← holder})"
        -- the old container exits (restart) and comes back as a standby
        let exited ← waitForCondition "the old leader's container restarted" 90 do
          return (← restarts old) > rOld
        if !exited then return .fail s!"{old} logged / lost authority but its container did not exit within 90 s of the new leader (restartCount stayed {rOld})"
        let oldLog ← podLog old true
        let newLog ← podLog standby false
        let some (tf, fl) := oldLog.find? (fun (_, l) => containsSubstr l "LEASE FAIL-CLOSED")
          | return .fail s!"the old leader never logged LEASE FAIL-CLOSED (its previous container's log has {oldLog.length} timestamped lines)"
        IO.eprintln s!"# old leader fail-closed at {tf}: {fl.take 160}"
        let served := oldLog.filter fun (_, l) => containsSubstr l "[DEBUG] Received command"
        let lastServed := (served.map (·.1)).foldl max 0
        let some (ta, _) := newLog.find? (fun (_, l) => containsSubstr l "phase 2: acquired lease")
          | return .fail s!"the standby {standby} did not log 'phase 2: acquired lease'"
        let tr ← transitions
        IO.eprintln s!"# stall at {s0}..{s1}; old fail-closed {tf} ({tf - s1} ms after the touch); old last served index request {lastServed} ({served.length} requests); standby acquired (log) {ta}; generation {t0} -> {tr}; standby seen holding at {th}"
        if tf < s0 + 5000 then
          return .fail s!"the old leader stepped down {tf - s0} ms after the stall began: before any deadline could have passed (it must wait for heldUntil, not step down at the first error)"
        if tf > s1 + 13500 then
          return .fail s!"the old leader stepped down {tf - s1} ms after the stall began: later than heldUntil = last confirmed send + 12 s (+ watchdog 0.5 s)"
        if lastServed > tf then
          return .fail s!"the old leader received an index request at {lastServed}, {lastServed - tf} ms AFTER its LEASE FAIL-CLOSED line {tf}: it kept serving past the deadline"
        if ta - tf < 1000 then
          return .fail s!"the standby acquired the lease at {ta}, only {ta - tf} ms after the old leader's fail-closed line {tf} (the margin is 3 s less the whole-second lease expiry check): the old leader may have served while the new one held"
        if tr != t0 + 1 then
          return .fail s!"the lease generation moved {t0} -> {tr}, expected {t0 + 1} (exactly one takeover)"
        -- the Service never routes to the old pod once the new leader holds the lease (3 s endpoints propagation)
        let routed := samples.filter fun (t, h, eps) => h == standby && t ≥ th + 3000 && eps.contains oldIp
        if let some (t, _, eps) := routed.head? then
          return .fail s!"the index Service still routed to the old leader {old} ({oldIp}) at {t}, {t - th} ms after the new leader held the lease: endpoints {eps}"
        let early := samples.filter fun (t, h, eps) => h == standby && t < th + 3000 && eps.contains oldIp
        IO.eprintln s!"# endpoint samples with the old pod while the new one held, inside the 3 s propagation allowance: {early.length}"
        discard <| waitForCondition "the old pod is a standby again" 120 do
          return (← holder) == standby
        return .pass }
  ] }

end FlareOperator.E2E.Tests.LeaseFailClosed
