/-
  lease_guard_probe LEASE NS IDENTITY SECONDS — host-runnable probe of the REAL
  lease guard (LeaseGuardApi.realLeaseApi: the same bounded kubectl calls, the
  same renewer and watchdog tasks as the operator) in OBSERVE mode.

  * creates the Lease LEASE in NS held by IDENTITY if it is absent (and deletes
    it at the end); an existing Lease is used only if IDENTITY already holds it,
    otherwise the probe stops without touching it;
  * runs ONLY the renewer + watchdog (no reconcile loop) for SECONDS seconds,
    printing every renewer outcome (one line per attempt) and every moment the
    watchdog WOULD have fired (it only prints; the process never exits early,
    nothing is labelled, no index serving exists here);
  * touches nothing but that one Lease. Expectation on a healthy API: every
    attempt "renew applied", heldUntil keeps moving, the watchdog never fires.
-/
import FlareOperator.LeaseGuardApi
import FlareOperator.Kubectl

open FlareOperator FlareOperator.K8s.Bridge FlareOperator.LeaseGuard

def probeMain (lease ns identity : String) (seconds : Nat) : IO UInt32 := do
  let say (m : String) : IO Unit := do
    IO.println m
    (← IO.getStdout).flush
  let mut created := false
  match ← getLease lease ns with
  | .ok l =>
    if l.holderIdentity != identity then
      say s!"probe: lease {lease} exists in {ns} held by '{l.holderIdentity}', not '{identity}': not touching it"
      return 2
    say s!"probe: lease {lease} exists and names {identity}: using it (it will NOT be deleted)"
  | .error _ =>
    match ← createLease lease ns identity 15 with
    | .ok () =>
      created := true
      say s!"probe: created lease {lease} in {ns} held by {identity}"
    | .error e =>
      say s!"probe: cannot create lease: {e}"
      return 2
  let sendMs ← IO.monoMsNow
  let applied ← IO.mkRef 0
  let failed ← IO.mkRef 0
  let raised ← IO.mkRef 0
  let wouldFire ← IO.mkRef 0
  let real := realLeaseApi lease ns identity
  let t0 ← IO.monoMsNow
  let api : Api := { real with
    log := fun m => do
      if m.startsWith "renewer: renew applied" then applied.modify (· + 1)
      else if m.startsWith "renewer: renew FAILED" then failed.modify (· + 1)
      else if m.startsWith "renewer: attempt RAISED" || (m.splitOn "DIED").length > 1 then raised.modify (· + 1)
      say s!"[+{(← IO.monoMsNow) - t0} ms] {m}" }
  -- OBSERVE: onExpire only reports; the guard is re-armed so the run goes on
  let gRef ← IO.mkRef (none : Option Guard)
  let lastKey ← IO.mkRef (none : Option (Nat × Bool))
  let g ← Guard.new { identity } (fun why => do
    if let some g ← gRef.get then
      let key := (← g.heldUntil.get, ← g.lost.get)
      if (← lastKey.get) != some key then
        lastKey.set (some key)
        wouldFire.modify (· + 1)
        say s!"[+{(← IO.monoMsNow) - t0} ms] WATCHDOG WOULD FIRE (observe mode, not exiting): {why}"
      g.fired.set none
      g.lost.set false)
  gRef.set (some g)
  -- the acquire's confirmation (the operator's loop does this at the acquire)
  g.confirm sendMs
  say s!"probe: guard armed, heldUntil={← g.heldUntil.get} ms; running {seconds} s"
  startTasks api g
  IO.sleep (seconds * 1000).toUInt32
  say s!"probe: summary: renews applied={← applied.get} failed={← failed.get} raised/died={← raised.get} watchdog-would-fire={← wouldFire.get}"
  if created then
    match ← Kubectl.kubectl ["delete", "lease", lease, "-n", ns, "--ignore-not-found"] with
    | .ok _ => say s!"probe: deleted lease {lease}"
    | .error e => say s!"probe: delete failed: {e}"
  let ok := (← failed.get) == 0 && (← raised.get) == 0 && (← wouldFire.get) == 0 && (← applied.get) > 0
  say (if ok then "probe: RESULT ok (renewer confirmed every attempt, watchdog never fired)"
       else "probe: RESULT PROBLEM (see the lines above)")
  return (if ok then 0 else 1)

def main (args : List String) : IO UInt32 :=
  match args with
  | [lease, ns, identity, secs] =>
    match secs.toNat? with
    | some s => probeMain lease ns identity s
    | none => do IO.eprintln "SECONDS must be a number"; return 64
  | _ => do IO.eprintln "usage: lease_guard_probe LEASE NS IDENTITY SECONDS"; return 64
