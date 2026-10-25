/-
  E2E/Tests/LeaseFailClosed.lean - the leader's lease deadline is fail-closed

  Two operator replicas (a leader and a standby; the index Service selects the
  `role=leader` pod). The leader's lease guard (StateMachine/LeaseGuard) keeps a
  LOCAL deadline heldUntil = send + 15 s - 3 s of its last positively confirmed
  renew; when it passes without a newer confirmation the leader stops serving
  index traffic, drops health leader, labels itself standby and exits.

  0. exact image: inside the LEADER pod (the operator image under test, not the
     host / CI runner) record PATH, which timeout / kubectl, their versions, a
     whole-second and a fractional `timeout` (rc, elapsed), and one REAL bounded
     Lease patch with the renewer's argv (timeout -k 1 <whole s> kubectl patch
     lease ... renewTime=<µs stamp>) on a scratch Lease, read back exactly.
     Required: `timeout -s KILL 1` (the renewer's argv) kills a TERM-ignoring
     child (rc 137) and a TERM-ignoring grandchild under sh -c by the 1 s wall
     (0.9-1.6 s, no late output); the patch applied within its 4 s wall; the
     read-back renewTime equals the stamp. The fractional and `-k 1` results
     are recorded only (the renewer uses neither).
  1. control: no stall, reconcile passes stretched to 16 s (test seam
     FLARE_TEST_RECONCILE_PASS_DELAY_FILE) for 4 minutes: no step-down, no
     restart, same holder, same generation (a spurious fail-closed would be a
     regression of the renewer). Also from the leader's own log: the renewer
     task started, no renew FAILED line, and at least 2 renews APPLIED inside one
     stretched pass (the renewer, not the loop, keeps the lease across it).
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
  3. incarnation fencing (same pod, two incarnations): the standby's lease API is
     stalled (it cannot take over); the leader's lease API is stalled, so its
     renewer's next request never reaches the server — that request (the exact
     `LeaseGuard.renewPatch` bytes: resourceVersion CAS on the state it knew,
     holder test, a fresh renewTime) is held back by the test. The leader fails
     closed and its container restarts in the SAME pod (same identity, fresh
     /tmp). Once the new incarnation has renewed, the held request is released:
     it must be REFUSED, and the lease keeps the new incarnation's holder,
     renewTime (never moved back) and transitions. A control on a scratch Lease
     shows the 477280c holder-only patch DOES move renewTime back on the real API.
  5. Lease deleted (StateMachine/LeaseAbsence): the Lease is created again only
     after >= 18 s of observed absence, after the old leader's LEASE FAIL-CLOSED,
     and the old leader served no index request after that creation.
  6. Lease deleted while the standby's lease API is stalled: the standby never
     creates it (an unreadable Lease is not an absence); the old leader's
     restarted incarnation creates it after the absence wait.
  Test 0 also checks the first start: the first leader created the Lease only
  after >= 18 s of absence.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.StateMachine.LeaseGuard

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
  -- the lease-API stall must survive the stalled leader's container restart (same pod, fresh /tmp):
  -- otherwise its new incarnation re-acquires at once and the standby never gets the lease
  operatorSeamDir := true
  operatorEnv := [("FLARE_TEST_LEASE_API_STALL_FILE", "/seam/lease-stall"),
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

/-- One exec in the leader pod; the whole stdout (or the error). -/
private def probeScript (lease stamp : String) : String :=
  "echo PATH=$PATH; echo timeout_bin=$(command -v timeout); echo kubectl_bin=$(command -v kubectl); " ++
  "echo timeout_version=$(timeout --version 2>&1 | head -1); " ++
  "echo kubectl_client=$(kubectl version --client 2>&1 | head -1); " ++
  "s=$(date +%s%N); timeout -s KILL 1 sh -c 'trap \"\" TERM; sleep 5'; rc=$?; e=$(date +%s%N); echo kill_rc=$rc kill_ms=$(( (e-s)/1000000 )); " ++
  "s=$(date +%s%N); X=$(timeout -s KILL 1 sh -c 'Y=$(sh -c \"trap \\\"\\\" TERM; sleep 5; echo late\"); echo $Y'); rc=$?; e=$(date +%s%N); echo gc_rc=$rc gc_ms=$(( (e-s)/1000000 )) gc_out=[$X]; " ++
  "s=$(date +%s%N); timeout -k 1 1 sh -c 'trap \"\" TERM; sleep 5'; rc=$?; e=$(date +%s%N); echo k1_rc=$rc k1_ms=$(( (e-s)/1000000 )); " ++
  "s=$(date +%s%N); timeout -k 1 0.300 sleep 2; rc=$?; e=$(date +%s%N); echo frac_rc=$rc frac_ms=$(( (e-s)/1000000 )); " ++
  "echo stamp_fmt=$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ); " ++
  s!"s=$(date +%s%N); timeout -s KILL 4 kubectl patch lease {lease} -n {ns} --type=json -p '[\{\"op\":\"test\",\"path\":\"/spec/holderIdentity\",\"value\":\"lease-probe\"},\{\"op\":\"replace\",\"path\":\"/spec/renewTime\",\"value\":\"{stamp}\"}]' >/dev/null 2>/tmp/probe-err; rc=$?; e=$(date +%s%N); echo patch_rc=$rc patch_ms=$(( (e-s)/1000000 )) patch_err=$(head -c 200 /tmp/probe-err | tr '\\n' ' '); " ++
  s!"echo readback=$(timeout -s KILL 4 kubectl get lease {lease} -n {ns} -o jsonpath='\{.spec.renewTime}')"

/-- `key=value` of the probe output. -/
private def field (out key : String) : String :=
  match (out.splitOn "\n").find? (·.startsWith s!"{key}=") with
  | some l => (l.drop (key.length + 1)).trim
  | none => ""

/-- `k=v` inside a line of several space-separated pairs. -/
private def pair (out key : String) : String :=
  let toks := (out.splitOn "\n").foldl (fun acc l => acc ++ l.splitOn " ") []
  match toks.find? (·.startsWith s!"{key}=") with
  | some t => t.drop (key.length + 1)
  | none => ""

def suite : TestSuite := {
  name := "operator-lease-failclosed"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    if !(← waitForStable cfg 50) then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics ns s!"app={cfg.operatorName}"
  teardown := cleanupCluster cfg
  tests := [
    { name := "(exact image) inside the leader pod: PATH, timeout / kubectl and versions, whole-second and fractional timeout, and a REAL bounded Lease patch with the renewer's argv read back exactly"
      run := do
        let some leader ← waitLeader | return .fail "no operator pod holds the lease with role=leader within 180 s"
        let probe := s!"{cfg.name}-probe-lease"
        let now ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%S.000000Z"] }
        let manifest := s!"apiVersion: coordination.k8s.io/v1\nkind: Lease\nmetadata:\n  name: {probe}\n  namespace: {ns}\nspec:\n  holderIdentity: lease-probe\n  leaseDurationSeconds: 15\n  renewTime: \"{now.stdout.trim}\"\n"
        match ← kubectlApplyManifest manifest with
        | .error e => return .fail s!"could not create the scratch Lease {probe}: {e}"
        | .ok _ => pure ()
        let st ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%S.%6NZ"] }
        let stamp := st.stdout.trim
        let r ← execIn leader (probeScript probe stamp)
        discard <| kubectl ["delete", "lease", probe, "-n", ns, "--ignore-not-found"]
        match r with
        | .error e => return .fail s!"the probe could not run in {leader}: {e}"
        | .ok out =>
          for l in out.splitOn "\n" do
            if !l.trim.isEmpty then IO.eprintln s!"# [exact image {leader}] {l.trim}"
          let killRc := pair out "kill_rc"
          let killMs := (pair out "kill_ms").toNat?.getD 0
          let gcRc := pair out "gc_rc"
          let gcMs := (pair out "gc_ms").toNat?.getD 0
          let patchRc := pair out "patch_rc"
          let rb := field out "readback"
          if field out "timeout_bin" == "" || field out "kubectl_bin" == "" then
            return .fail s!"timeout or kubectl not on PATH in the operator image: {out.take 400}"
          if killRc != "137" || killMs < 900 || killMs > 1600 then
            return .fail s!"`timeout -s KILL 1` on a TERM-ignoring child in the operator image: rc {killRc}, {killMs} ms (expected 137 after ~1 s: KILL at the wall)"
          if gcMs < 900 || gcMs > 1600 || (pair out "gc_out") != "[]" then
            return .fail s!"`timeout -s KILL 1` did not kill a TERM-ignoring GRANDCHILD by the wall in the operator image: rc {gcRc}, {gcMs} ms, output {pair out "gc_out"} (the bounded lease read runs kubectl under sh)"
          if patchRc != "0" then
            return .fail s!"the bounded Lease patch with the renewer's argv failed in the operator image: rc {patchRc} after {pair out "patch_ms"} ms: {out.take 600}"
          if rb != stamp then
            return .fail s!"the read-back renewTime '{rb}' is not the written stamp '{stamp}' (the guard's ambiguous-result confirmation compares exactly)"
          -- first start: the Lease did not exist; whoever created it waited lease + margin of absence
          let mut created : Option String := none
          for pod in ← operatorPods do
            for prevC in [false, true] do
              for (_, l) in ← podLog pod prevC do
                if containsSubstr l "lease absence:" && containsSubstr l ": creating it" then created := some l
          match created with
          | none => return .fail "first start: no operator logged creating the Lease after an observed absence"
          | some l =>
            let n := (((l.splitOn "absent for ").getD 1 "").takeWhile Char.isDigit).toNat?.getD 0
            IO.eprintln s!"# first start: {l.take 200}"
            if n < 18000 then return .fail s!"first start: the Lease was created after only {n} ms of absence (< 18000): {l.take 200}"
          return .pass },

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
        -- the leader's own renewer kept the lease across a stretched pass (not the loop)
        let ll ← podLog leader false
        if !(ll.any fun (_, l) => containsSubstr l "renewer: task started") then
          return .fail s!"the leader {leader} never logged 'renewer: task started'"
        if let some (_, l) := ll.find? (fun (_, l) => containsSubstr l "renewer: renew FAILED" || containsSubstr l "renewer: task DIED" || containsSubstr l "renewer: attempt RAISED") then
          return .fail s!"the leader's renewer failed during the control: {l.take 300}"
        let applied := (ll.filter fun (_, l) => containsSubstr l "renewer: renew applied").map (·.1)
        let stretches := (ll.filter fun (_, l) => containsSubstr l "TEST SEAM: reconcile pass stretched").map (·.1)
        let best := stretches.foldl (fun acc ts => max acc (applied.filter (fun t => t > ts && t < ts + 16000)).length) 0
        IO.eprintln s!"# leader {leader}: {applied.length} renews applied, {stretches.length} stretched passes, at most {best} applied inside one stretched pass"
        if best < 2 then
          return .fail s!"at most {best} renew(s) APPLIED inside one stretched 16 s pass (need >= 2): the lease was not kept by the renewer across a long pass"
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
        match ← execIn old "touch /seam/lease-stall" with
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
        -- the stall survived the old pod's container restart (pod-level /seam): lift it so it comes back as a standby
        discard <| execIn old "rm -f /seam/lease-stall"
        discard <| waitForCondition "the old pod is a standby again" 120 do
          return (← holder) == standby
        return .pass },
    { name := "(incarnation fencing) a renew of the killed incarnation, held back and released after the same pod restarted and renewed, is refused by the resourceVersion CAS; holder, renewTime and transitions stay the new incarnation's (control: 477280c's holder-only patch moves renewTime back)"
      run := do
        let some leader ← waitLeader | return .fail "no operator pod holds the lease with role=leader within 180 s"
        let pods ← operatorPods
        let some standby := pods.find? (· != leader) | return .fail s!"no standby among {pods}"
        let stamp := fun (_ : Unit) => do
          let r ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%S.%6NZ"] }
          return r.stdout.trim
        -- control on a scratch Lease (the cluster's lease is not touched by it)
        let probe := s!"{cfg.name}-fence-probe"
        let now0 ← stamp ()
        let mk := s!"apiVersion: coordination.k8s.io/v1\nkind: Lease\nmetadata:\n  name: {probe}\n  namespace: {ns}\nspec:\n  holderIdentity: {leader}\n  leaseDurationSeconds: 15\n  renewTime: \"{now0}\"\n"
        match ← kubectlApplyManifest mk with
        | .error e => return .fail s!"could not create the scratch Lease: {e}"
        | .ok _ => pure ()
        let pf := fun (path : String) => do
          match ← kubectlGetJsonpath "lease" probe ns path with
          | .ok v => return v.trim
          | .error _ => return ""
        let rvA ← pf "{.metadata.resourceVersion}"
        let oldStamp ← stamp ()
        let oldCas := LeaseGuard.patchJson (LeaseGuard.renewPatch leader oldStamp rvA)
        let oldHolderOnly := LeaseGuard.patchJson [.test "/spec/holderIdentity" leader, .replace "/spec/renewTime" oldStamp]
        IO.sleep 1100
        let newStamp ← stamp ()
        match ← kubectl ["patch", "lease", probe, "-n", ns, "--type=json", "-p", LeaseGuard.patchJson (LeaseGuard.renewPatch leader newStamp rvA)] with
        | .error e => return .fail s!"control: the new incarnation's renew on the scratch Lease failed: {e}"
        | .ok _ => pure ()
        let casRes ← kubectl ["patch", "lease", probe, "-n", ns, "--type=json", "-p", oldCas]
        let afterCas ← pf "{.spec.renewTime}"
        let hoRes ← kubectl ["patch", "lease", probe, "-n", ns, "--type=json", "-p", oldHolderOnly]
        let afterHo ← pf "{.spec.renewTime}"
        discard <| kubectl ["delete", "lease", probe, "-n", ns, "--ignore-not-found"]
        IO.eprintln s!"# control (scratch Lease): new renewTime {newStamp}; late rv-CAS patch {match casRes with | .ok _ => "APPLIED" | .error _ => "refused"} -> {afterCas}; late holder-only patch (477280c) {match hoRes with | .ok _ => "APPLIED" | .error _ => "refused"} -> {afterHo} (old stamp {oldStamp})"
        if casRes.isOk || afterCas != newStamp then
          return .fail s!"control: the late rv-CAS patch was not refused on the real API (renewTime now {afterCas}, new {newStamp})"
        if !(hoRes.isOk && afterHo == oldStamp) then
          return .fail s!"control: the holder-only patch did not move renewTime back on the real API ({afterHo}); the control did not reproduce the 477280c hazard"
        -- the real lease: the standby cannot take over; the leader's renewer is cut from the server
        match ← execIn standby "touch /seam/lease-stall" with
        | .error e => return .fail s!"could not stall the standby's lease API: {e}"
        | .ok _ => pure ()
        let r0 ← restarts leader
        match ← execIn leader "touch /seam/lease-stall" with
        | .error e => return .fail s!"could not stall the leader's lease API: {e}"
        | .ok _ => pure ()
        IO.sleep 500
        let rvOld ← leaseField "{.metadata.resourceVersion}"
        let t0 ← transitions
        let heldStamp ← stamp ()
        let held := LeaseGuard.patchJson (LeaseGuard.renewPatch leader heldStamp rvOld)
        IO.eprintln s!"# the old incarnation's next renew is held back: CAS on rv {rvOld}, stamp {heldStamp} (holder {leader}, transitions {t0})"
        -- the old incarnation fails closed, the container restarts in the same pod, the new incarnation renews
        let restarted ← waitForCondition s!"{leader}'s container restarted" 120 do
          return (← restarts leader) > r0
        if !restarted then
          discard <| execIn standby "rm -f /seam/lease-stall"
          discard <| execIn leader "rm -f /seam/lease-stall"
          return .fail s!"{leader} did not restart within 120 s of its lease API stall"
        -- the new incarnation (same pod, same identity) gets its lease API back; the standby stays stalled
        discard <| execIn leader "rm -f /seam/lease-stall"
        let renewed ← waitForCondition "the new incarnation renewed (holder unchanged, resourceVersion moved)" 120 do
          return (← holder) == leader && (← leaseField "{.metadata.resourceVersion}") != rvOld &&
            ((← podLog leader false).any fun (_, l) => containsSubstr l "renewer: renew applied")
        if !renewed then
          discard <| execIn standby "rm -f /seam/lease-stall"
          return .fail s!"the new incarnation of {leader} did not renew within 120 s (holder {← holder})"
        let rtNew ← leaseField "{.spec.renewTime}"
        -- release the old incarnation's request
        let res ← kubectl ["patch", "lease", leaseName, "-n", ns, "--type=json", "-p", held]
        let rtAfter ← leaseField "{.spec.renewTime}"
        let hAfter ← holder
        let tAfter ← transitions
        discard <| execIn standby "rm -f /seam/lease-stall"
        IO.eprintln s!"# released the held request: {match res with | .ok _ => "APPLIED" | .error e => s!"refused ({e.take 160})"}; lease holder {hAfter}, renewTime {rtNew} -> {rtAfter}, transitions {t0} -> {tAfter}"
        if res.isOk then
          return .fail s!"the old incarnation's late renew was APPLIED to the new incarnation's lease (renewTime {rtNew} -> {rtAfter}): not fenced"
        if hAfter != leader || tAfter != t0 then
          return .fail s!"the lease changed hands or generation during the test: holder {hAfter}, transitions {t0} -> {tAfter}"
        if rtAfter == heldStamp || rtAfter < rtNew then
          return .fail s!"renewTime moved back: {rtNew} -> {rtAfter} (held stamp {heldStamp})"
        return .pass },
    { name := "(lease deleted) the Lease is created again only after >= 18 s of observed absence, after the old leader failed closed, and the old leader served nothing after the creation"
      run := do
        let some old ← waitLeader | return .fail "no operator pod holds the lease with role=leader within 180 s"
        let pods ← operatorPods
        let some standby := pods.find? (· != old) | return .fail s!"no standby among {pods}"
        let r0 ← restarts old
        let d ← wallMs
        match ← kubectl ["delete", "lease", leaseName, "-n", ns] with
        | .error e => return .fail s!"could not delete the Lease: {e}"
        | .ok _ => pure ()
        IO.eprintln s!"# lease deleted at {d} (holder was {old}, standby {standby})"
        let back ← waitForCondition "the Lease exists again with a holder" 240 do
          return !(← holder).isEmpty
        if !back then return .fail "the Lease was not created again within 240 s of its deletion"
        let h ← holder
        let restarted ← waitForCondition s!"{old}'s container restarted (fail-closed exit)" 120 do
          return (← restarts old) > r0
        if !restarted then return .fail s!"the old leader {old} did not fail closed and restart after the deletion"
        let oldPrev ← podLog old true
        let some (tf, _) := oldPrev.find? (fun (t, l) => t ≥ d && containsSubstr l "LEASE FAIL-CLOSED")
          | return .fail s!"the old leader {old} logged no LEASE FAIL-CLOSED after the deletion"
        -- the creator's own log: the creation line and how long it observed the absence
        let creatorLog ← podLog h false
        let some (tc, cl) := creatorLog.find? (fun (t, l) => t ≥ d && containsSubstr l "lease absence:" && containsSubstr l ": creating it")
          | return .fail s!"the new holder {h} logged no creation after an observed absence"
        let n := (((cl.splitOn "absent for ").getD 1 "").takeWhile Char.isDigit).toNat?.getD 0
        let served := oldPrev.filter fun (_, l) => containsSubstr l "[DEBUG] Received command"
        let lastServed := (served.map (·.1)).foldl max 0
        IO.eprintln s!"# deletion {d}; old {old} fail-closed {tf} (+{tf - d} ms), last served index request {lastServed}; new holder {h} created at {tc} (+{tc - d} ms) after {n} ms of observed absence"
        if n < 18000 then return .fail s!"{h} created the Lease after only {n} ms of observed absence"
        if tc + 500 < d + 18000 then return .fail s!"{h} created the Lease {tc - d} ms after the deletion (< 18 s)"
        if tc ≤ tf then return .fail s!"{h} created the Lease at {tc}, not after the old leader's fail-closed {tf}: a window with two leaders"
        if lastServed > tc then return .fail s!"the old leader received an index request at {lastServed}, after the new Lease existed ({tc})"
        let _ ← waitLeader
        return .pass },

    { name := "(lease deleted, standby's lease API unreadable) an unreadable Lease is not an absence: the stalled standby never creates it; the old leader's restarted incarnation creates it after the absence wait"
      run := do
        let some old ← waitLeader | return .fail "no operator pod holds the lease with role=leader within 180 s"
        let pods ← operatorPods
        let some standby := pods.find? (· != old) | return .fail s!"no standby among {pods}"
        match ← execIn standby "touch /seam/lease-stall" with
        | .error e => return .fail s!"could not stall the standby's lease API: {e}"
        | .ok _ => pure ()
        let d ← wallMs
        match ← kubectl ["delete", "lease", leaseName, "-n", ns] with
        | .error e =>
          discard <| execIn standby "rm -f /seam/lease-stall"
          return .fail s!"could not delete the Lease: {e}"
        | .ok _ => pure ()
        let back ← waitForCondition "the Lease exists again with a holder" 240 do
          return !(← holder).isEmpty
        let h ← holder
        let sLog ← podLog standby false
        discard <| execIn standby "rm -f /seam/lease-stall"
        if !back then return .fail "the Lease was not created again within 240 s"
        let created := sLog.filter fun (t, l) => t ≥ d && containsSubstr l ": creating it"
        let observed := sLog.filter fun (t, l) => t ≥ d && containsSubstr l "is NotFound; observing"
        IO.eprintln s!"# deletion {d} with the standby {standby} stalled: new holder {h}; standby create lines {created.length}, absence-observation lines {observed.length}"
        if h == standby then return .fail s!"the stalled standby {standby} created the Lease"
        if !created.isEmpty then return .fail s!"the stalled standby logged a create: {(created.head?.map (·.2)).getD ""}"
        if !observed.isEmpty then return .fail s!"the stalled standby started an absence observation from unreadable readings"
        if h != old then return .fail s!"unexpected holder {h} (expected the old leader's restarted incarnation {old})"
        let hLog ← podLog h false
        let some (tc, cl) := hLog.find? (fun (t, l) => t ≥ d && containsSubstr l ": creating it")
          | return .fail s!"{h} logged no creation after an observed absence"
        let n := (((cl.splitOn "absent for ").getD 1 "").takeWhile Char.isDigit).toNat?.getD 0
        if n < 18000 || tc + 500 < d + 18000 then return .fail s!"{h} created the Lease after {n} ms of absence, {tc - d} ms after the deletion"
        let _ ← waitLeader
        return .pass }
  ] }

end FlareOperator.E2E.Tests.LeaseFailClosed
