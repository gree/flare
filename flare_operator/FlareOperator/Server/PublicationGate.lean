/-
  Publication gate: a node registration and a node-map send never overlap.

  The window it closes (CI 38090211947, the residual of 0582f2d): a reconcile
  pass checks that its snapshot is still the live map and then sends it; a
  `node add` answered by the TCP server between that check and the arrival of
  the send advances the live map, but the new node holds its registration
  reply as version 0 and accepts the older snapshot (flared
  cluster::reconstruct_node only refuses a version LOWER than one it holds,
  and only once it holds one above 0) — the node takes the old map's entry
  for itself instead of the role it was just given.

  Why not a lock around the send. flared answers a node sync only after
  reconstruct_node, and reconstruct_node re-announces an Active node to the
  operator (`node state`, activate_node) BEFORE it replies: a lock that also
  held `node state` would stall every such send until the broadcast deadline.
  `node add` is sent only from cluster::startup_node, before flared listens,
  so no send ever waits on a registration — registrations alone can wait for
  a send without a cycle. Nothing here holds a lock across network IO: the
  gate is a value updated atomically (IO.Ref.modifyGet), a send that cannot
  begin is skipped (it stays pending, the next pass publishes the live map),
  and a registration that cannot begin waits on the send's completion
  promise, bounded by `registrationWaitCeilingMs`.

  NOT covered: `node state` / `node role` reports during a send still move
  the live map (logged after the send as before).
-/

namespace FlareOperator.Server

/-- At most one send (the reconcile loop is the only sender) and any number
    of registrations, never both at once. -/
structure PublicationGate where
  sending : Option Nat := none
  registering : Nat := 0
  deriving Repr, BEq, DecidableEq, Inhabited

namespace PublicationGate

/-- A send of version `v` may begin only while no registration is between
    its start and its state change, and no other send is in flight. -/
def beginSend (g : PublicationGate) (v : Nat) : Bool × PublicationGate :=
  if g.sending.isNone && g.registering == 0 then (true, { g with sending := some v })
  else (false, g)

def endSend (g : PublicationGate) : PublicationGate := { g with sending := none }

/-- A registration may begin only while no send is in flight. -/
def beginRegistration (g : PublicationGate) : Bool × PublicationGate :=
  if g.sending.isNone then (true, { g with registering := g.registering + 1 })
  else (false, g)

/-- The forced form, used only once the wait ceiling is exceeded: it is
    counted (so no NEW send begins until it ends) but does not wait for the
    one in flight. -/
def forceRegistration (g : PublicationGate) : PublicationGate :=
  { g with registering := g.registering + 1 }

def endRegistration (g : PublicationGate) : PublicationGate :=
  { g with registering := g.registering - 1 }

/-- Once a send has begun, no registration begins until it ends. -/
theorem no_registration_during_send (g : PublicationGate) (v : Nat)
    (h : (g.beginSend v).1 = true) :
    ((g.beginSend v).2.beginRegistration).1 = false := by
  unfold beginSend at *
  split at h <;> simp_all [beginRegistration]

/-- While a registration is counted, no send begins. -/
theorem no_send_during_registration (g : PublicationGate) (v : Nat)
    (h : g.beginRegistration.1 = true) :
    (g.beginRegistration.2.beginSend v).1 = false := by
  unfold beginRegistration at *
  split at h <;> simp_all [beginSend]

end PublicationGate

/-- flared waits 30 s for its registration reply in the k8s build
    (connection_tcp::effective_read_timeout_ms); the send this waits for is
    bounded at 15 s (broadcastTopologyToAllPods). -/
def registrationWaitCeilingMs : Nat := 20000

initialize publicationGateRef : IO.Ref PublicationGate ← IO.mkRef {}
/-- Completion of the send in flight (resolved `true` when it ends). -/
initialize sendDoneRef : IO.Ref (Option (IO.Promise Bool)) ← IO.mkRef none

/-- Begin a send of `v`. Returns the promise to resolve with `endPublication`,
    or none when a registration is in progress (the caller skips the send). -/
def tryBeginPublication (v : Nat) : IO (Option (IO.Promise Bool)) := do
  let p ← IO.Promise.new
  -- published before the gate closes, so a registration refused by the
  -- gate always finds a promise to wait on
  sendDoneRef.set (some p)
  let began ← publicationGateRef.modifyGet fun g => g.beginSend v
  if began then return some p
  p.resolve true
  return none

def endPublication (p : IO.Promise Bool) : IO Unit := do
  publicationGateRef.modify PublicationGate.endSend
  p.resolve true

/-- Wait (on the send's promise, never by sleeping in a pool thread) until a
    registration may begin, at most `registrationWaitCeilingMs`. `who` names
    the registering node in the log. -/
def beginRegistrationWaiting (who : String) : IO Unit := do
  let start ← IO.monoMsNow
  let mut logged := false
  repeat
    let began ← publicationGateRef.modifyGet PublicationGate.beginRegistration
    if began then
      if logged then
        IO.eprintln s!"[flare-operator] registration of {who} proceeds after the send ({(← IO.monoMsNow) - start} ms)"
      return
    let elapsed := (← IO.monoMsNow) - start
    if elapsed ≥ registrationWaitCeilingMs then
      publicationGateRef.modify PublicationGate.forceRegistration
      IO.eprintln s!"[flare-operator] WARNING: registration of {who} proceeds while a node-map send is still in flight after {elapsed} ms (ceiling); the node may take that older map until the next pass publishes the live one"
      return
    let g ← publicationGateRef.get
    if !logged then
      IO.eprintln s!"[flare-operator] registration of {who} waits for the in-flight node-map send of v{g.sending.getD 0}"
      logged := true
    match ← sendDoneRef.get with
    | none => pure ()
    | some p =>
      let remaining := registrationWaitCeilingMs - elapsed
      let timer ← IO.asTask (prio := .dedicated) (do IO.sleep remaining.toUInt32; pure false)
      discard <| IO.waitAny [p.resultD true, timer.map (fun _ => false)]

def endRegistrationGate : IO Unit :=
  publicationGateRef.modify PublicationGate.endRegistration

end FlareOperator.Server
