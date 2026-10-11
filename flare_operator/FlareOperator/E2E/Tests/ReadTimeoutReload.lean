/-
  flared::reload() keeps the read timeout it started with.

  flared.cc applies connection_tcp::effective_read_timeout_ms at startup
  AND in reload(): in the k8s build 30 s unless net-read-timeout is set
  explicitly. Before that fix reload() applied net_read_timeout
  unconditionally, so a SIGHUP (the operator sends one on every extra.conf
  change) turned 30 s into 600 s. The rule itself has unit checks
  (test_connection_tcp.cc); nothing exercised reload() — these tests do,
  through behaviour: a client that sends half a command is disconnected by
  flared after the read timeout in force, measured from the client.

  A measurement that never sees the close (nc not exiting on a remote
  close, a timeout above the cap) reads as the cap and FAILS both the 30 s
  and the explicit-value checks — it cannot pass by not measuring.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ReadTimeoutReload

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "rto-reload"
  «namespace» := "flare-rto-reload"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator"
  debugPod := "debug-rto-reload"
}

private def pod : String := s!"{cfg.name}-nodes-0"
private def explicitSec : Nat := 8
/-- Measurement cap: well above 30 s, far below the 600 s default. -/
private def capSec : Nat := 75

private def sh (cmd : String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := "sh", args := #["-c", cmd] }
  if out.exitCode == 0 then return .ok out.stdout else return .error out.stderr

/-- Seconds until flared closes a connection that sent `get k` without the
    line end; `capSec` when it was not seen closing.

    Runs INSIDE the flared pod (bash /dev/tcp; `cat` ends exactly at the
    server's close), detached, writing its result to a file that is polled
    with short execs: the E2E kubectl wrapper kills any call after 30 s
    (Kubectl.lean), and busybox nc in the debug pod did not report the
    close (CI 38099188121 / 38099186230: no measurement in either case,
    not even the 8 s one). -/
private def closeAfterPartialCommand (_ip : String) : IO (Option Nat) := do
  let inner := s!"exec 3<>/dev/tcp/127.0.0.1/{cfg.flarePort}; printf \"get k\" >&3; s=$(date +%s); timeout {capSec} cat <&3 >/dev/null; echo $(( $(date +%s) - s )) > /tmp/rto.out"
  let start := s!"rm -f /tmp/rto.out; setsid -f bash -c '{inner}' </dev/null >/dev/null 2>&1; echo started"
  match ← kubectl ["exec", pod, "-n", cfg.«namespace», "--", "bash", "-c", start] with
  | .error e =>
    IO.eprintln s!"# measurement could not start: {e}"
    return none
  | .ok _ => pure ()
  for _ in [0:(capSec + 20) / 2] do
    IO.sleep 2000
    match ← kubectl ["exec", pod, "-n", cfg.«namespace», "--", "cat", "/tmp/rto.out"] with
    | .ok out =>
      if let some n := out.trim.toNat? then return some n
    | .error _ => pure ()
  return none

/-- `read timeout: N ms` lines flared printed (one per start / reload). -/
private def readTimeoutLines (log : String) : List Nat :=
  (log.splitOn "\n").filterMap fun l =>
    if !containsSubstr l "read timeout:" then none
    else
      let rest := (l.splitOn "read timeout:").getLast!.trim
      (rest.takeWhile Char.isDigit).toNat?

private def hup : IO (Except String String) :=
  kubectl ["exec", pod, "-n", cfg.«namespace», "--", "kill", "-HUP", "1"]

/-- SIGHUP flared and wait for the reload's `read timeout:` line. -/
private def reloadAndRead : IO (Except String Nat) := do
  let before := (readTimeoutLines (← kubectlLogs pod cfg.«namespace» 5000)).length
  match ← hup with
  | .error e => return .error s!"SIGHUP failed: {e}"
  | .ok _ => pure ()
  let mut got : Option Nat := none
  for _ in [0:30] do
    let ls := readTimeoutLines (← kubectlLogs pod cfg.«namespace» 5000)
    if ls.length > before then
      got := ls.getLast?
      break
    IO.sleep 1000
  match got with
  | none => return .error "flared printed no 'read timeout:' line after the SIGHUP: reload() did not run (or its log is gone)"
  | some ms => return .ok ms

private def mountedConf : IO String := do
  match ← kubectl ["exec", pod, "-n", cfg.«namespace», "--", "cat", "/etc/flared/extra.conf"] with
  | .ok s => return s
  | .error _ => return ""

def suite : TestSuite := {
  name := "read-timeout-reload"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      IO.eprintln "# WARNING: cluster did not stabilize during setup"
  teardown := cleanupCluster cfg
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  tests := [
    { name := "k8s build, net-read-timeout unset: flared starts at 30 s and a SIGHUP reload keeps 30 s (not the 600 s default) — measured by when flared drops a half-sent command"
      run := do
        match ← getPodIp pod cfg.«namespace» with
        | none => return .fail s!"no IP for {pod}"
        | some ip =>
          if containsSubstr (← mountedConf) "net-read-timeout" then
            return .fail "precondition: extra.conf already sets net-read-timeout"
          let startLines := readTimeoutLines (← kubectlLogs pod cfg.«namespace» 5000)
          IO.eprintln s!"# read timeout lines so far: {startLines}"
          let t0 ← closeAfterPartialCommand ip
          IO.eprintln s!"# before the reload: closed after {t0} s"
          match ← reloadAndRead with
          | .error e => return .fail e
          | .ok ms =>
            IO.eprintln s!"# reload printed read timeout {ms} ms"
            let t1 ← closeAfterPartialCommand ip
            IO.eprintln s!"# after the reload: closed after {t1} s (cap {capSec})"
            if ms != 30000 then return .fail s!"reload() set the read timeout to {ms} ms, expected 30000"
            match t0, t1 with
            | some a, some b =>
              if a < 25 || a > 40 then return .fail s!"before the reload the half-sent command was dropped after {a} s, expected about 30 (cap {capSec} = never seen)"
              if b < 25 || b > 40 then return .fail s!"after the reload the half-sent command was dropped after {b} s, expected about 30 (cap {capSec} = never seen; the old reload() made it 600)"
              return .pass
            | _, _ => return .fail s!"could not measure from the debug pod: {t0} / {t1}" },

    { name := s!"net-read-timeout = {explicitSec} set explicitly: a SIGHUP reload applies it, and a second reload with the file unchanged keeps it (measured)"
      run := do
        match ← getPodIp pod cfg.«namespace» with
        | none => return .fail s!"no IP for {pod}"
        | some ip =>
          let cm := s!"{cfg.name}-config"
          let edit := s!"kubectl get configmap {cm} -n {cfg.«namespace»} -o jsonpath='\{.data.extra\\.conf}' > /tmp/rto-extra.conf && printf '\\nnet-read-timeout = {explicitSec}\\n' >> /tmp/rto-extra.conf && kubectl create configmap {cm} -n {cfg.«namespace»} --from-file=extra.conf=/tmp/rto-extra.conf --dry-run=client -o yaml | kubectl apply -f -"
          match ← sh edit with
          | .error e => return .fail s!"could not add net-read-timeout to {cm}: {e}"
          | .ok _ => pure ()
          let mounted ← waitForCondition "the mounted extra.conf carries net-read-timeout" 180 do
            return containsSubstr (← mountedConf) s!"net-read-timeout = {explicitSec}"
          if !mounted then return .fail "the ConfigMap change never reached the pod's extra.conf"
          match ← reloadAndRead with
          | .error e => return .fail e
          | .ok ms1 =>
            let t1 ← closeAfterPartialCommand ip
            IO.eprintln s!"# first reload: {ms1} ms; dropped after {t1} s"
            if ms1 != explicitSec * 1000 then return .fail s!"the first reload set {ms1} ms, expected {explicitSec * 1000}"
            if !containsSubstr (← mountedConf) s!"net-read-timeout = {explicitSec}" then
              return .fail "extra.conf lost the line before the second reload (rewritten by the operator?) — the second reload would not test retention"
            match ← reloadAndRead with
            | .error e => return .fail e
            | .ok ms2 =>
              let t2 ← closeAfterPartialCommand ip
              IO.eprintln s!"# second reload: {ms2} ms; dropped after {t2} s"
              if ms2 != explicitSec * 1000 then return .fail s!"the second reload set {ms2} ms, expected {explicitSec * 1000} kept"
              match t1, t2 with
              | some a, some b =>
                let ok := fun (x : Nat) => x + 3 ≥ explicitSec && x ≤ explicitSec + 7
                if !ok a then return .fail s!"after the first reload dropped after {a} s, expected about {explicitSec}"
                if !ok b then return .fail s!"after the second reload dropped after {b} s, expected about {explicitSec}"
                return .pass
              | _, _ => return .fail s!"could not measure from the debug pod: {t1} / {t2}" }
  ]
}

end FlareOperator.E2E.Tests.ReadTimeoutReload
