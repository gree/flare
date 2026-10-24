/-
  WriteAuthorityChecks.lean — unit checks of the pure part of the C' wiring
  (WriteAuthority): config, membership record and its transitions, flared's
  status reply, and the gate's decision (exhaustive over a finite domain).
-/
import FlareOperator.StateMachine.WriteAuthority
import FlareOperator.StateMachine.PromotionEvidence

namespace FlareOperator.WriteAuthorityChecks

open FlareOperator.WriteAuthority

def mem (term gen : Nat) (master : String) (succ : List String) (acked := false) : Members :=
  { term, gen, master, successors := succ, acked }

def reply (state : String) (intent remaining : Nat) (promotable : Bool) (mode : String) (mt mg : Nat)
    (grant solo : Bool) : String :=
  let b : Bool → String := fun x => if x then "1" else "0"
  s!"STAT authority_enabled 1\r\nSTAT authority_refused 0\r\nSTAT promise_state {state}\r\nSTAT promise_intent {intent}\r\nSTAT promise_have 1\r\nSTAT promise_remaining_ms {remaining}\r\nSTAT promise_promotable {b promotable}\r\nSTAT floor_term 3\r\nSTAT floor_gen 4\r\nSTAT floor_set 1\r\nSTAT members_mode {mode}\r\nSTAT members_term {mt}\r\nSTAT members_gen {mg}\r\nSTAT members_successors -\r\nSTAT promise_term_next 0\r\nSTAT promise_gen 0\r\nSTAT promise_boot b1\r\nSTAT promise_copy c1\r\nSTAT identity_boot b1\r\nSTAT identity_copy c1\r\nSTAT members_boot b1\r\nSTAT members_copy c1\r\nSTAT grant_valid {b grant}\r\nSTAT grant_term 3\r\nSTAT grant_gen 4\r\nSTAT grant_solo {b solo}\r\nSTAT grant_remaining_ms 0\r\nEND\r\n"

def tConfig : Bool :=
  let ok := Config.ofValues (some 10000) (some 3000) (some 2000) (some 60000)
  ok.isSome
    && (Config.ofValues none (some 3000) (some 2000) (some 60000)).isNone
    && (Config.ofValues (some 10000) none (some 2000) (some 60000)).isNone
    && (Config.ofValues (some 10000) (some 3000) none (some 60000)).isNone
    && (Config.ofValues (some 10000) (some 3000) (some 2000) none).isNone
    && (Config.ofValues (some 10000) (some 10000) (some 2000) (some 60000)).isNone
    && (Config.ofValues (some 10000) (some 3000) (some 0) (some 60000)).isNone
    && (Config.ofValues (some 10000) (some 3000) (some 2000) (some 12000)).isNone

def tCodec : Bool :=
  let bd : Bind := { uid := "u", boot := "b1", copy := "c1" }
  let m : Members := { mem 3 7 "n-0.x.svc:12121" ["n-1.x.svc:12121", "n-2.x.svc:12121"] true with ackBind := some bd }
  let solo := mem 1 1 "n-0.x.svc:12121" []
  Members.decode m.encode == some m
    && Members.decode solo.encode == some solo
    && (Members.decode "v=2 term=03 gen=1 acked=0 master=a succ= ack=-").isNone
    && (Members.decode "v=2 term=3 gen=1 acked=0 master=a succ=").isNone
    && (Members.decode "v=1 term=3 gen=1 acked=0 master=a succ= ack=-").isNone
    && (Members.decode "v=2 gen=1 term=3 acked=0 master=a succ= ack=-").isNone
    && (Members.decode "v=2 term=3 gen=1 acked=2 master=a succ= ack=-").isNone
    && (Members.decode "v=2 term=3 gen=1 acked=0 master= succ= ack=-").isNone
    && (Members.decode "v=2 term=3 gen=1 acked=0 master=a succ=b,,c ack=-").isNone
    -- an acknowledgement names its incarnation; one without the other is broken
    && (Members.decode "v=2 term=3 gen=1 acked=1 master=a succ= ack=-").isNone
    && (Members.decode "v=2 term=3 gen=1 acked=0 master=a succ= ack=u,b1,c1").isNone
    && (Members.decode (m.encode ++ " extra=1")).isNone
    && (Members.decode "").isNone

def v1 (m : Option String) (s : List String) : View := { master := m, successors := s }

def tNext : Bool :=
  let a := "a:1"
  let b := "b:1"
  let c := "c:1"
  let o := mem 2 5 a [b] true
  -- first record
  Members.next none (v1 (some a) [b, c]) false none == some (mem 1 1 a [b, c])
    -- no master: nothing
    && Members.next (some o) (v1 none []) false none == some o
    -- same set: unchanged (acked stays)
    && Members.next (some o) (v1 (some a) [b]) false none == some o
    -- a changed set bumps the generation and needs a new ack
    && Members.next (some o) (v1 (some a) [b, c]) false none == some (mem 2 6 a [b, c])
    -- an observation without the member (rebuilding / not Ready / unreachable) removes nobody: never solo from it
    && Members.next (some o) (v1 (some a) []) false none == some o
    && Members.next (some o) { v1 (some a) [] with pods := none } false none == some o
    && Members.next (some o) { v1 (some a) [] with pods := some [a, b] } false none == some o
    -- only an authoritative removal (the pod list was read in full and the member's pod is gone) is solo, a new generation
    && Members.next (some o) { v1 (some a) [] with pods := some [a] } false none == some (mem 2 6 a [])
    -- a newly eligible node is added, the kept member stays
    && Members.next (some o) { v1 (some a) [c] with pods := some [a, b, c] } false none == some (mem 2 6 a [b, c])
    -- frozen by an unfinished intent: never changed (an old master does not get solo back)
    && Members.next (some o) (v1 (some a) []) true none == some o
    && Members.next (some o) (v1 (some a) [b, c]) true none == some o
    -- a master change without a committed intent keeps the old record (the new master gets no grant)
    && Members.next (some o) (v1 (some b) [a]) false none == some o
    && Members.next (some o) (v1 (some b) [a]) false (some c) == some o
    -- with the committed intent of the new master the term moves
    && Members.next (some o) (v1 (some b) [a, c]) false (some b) == some (mem 3 6 b [a, c])
    -- the master is never its own successor, order does not matter
    && Members.next none (v1 (some a) [c, a, b]) false none == some (mem 1 1 a [b, c])

def tStatus : Bool :=
  let m := mem 3 4 "a:1" ["b:1"]
  let solo := mem 3 4 "a:1" []
  let r1 := reply "following" 0 0 false "replicated" 3 4 true false
  let r2 := reply "preparing" 7 5000 false "none" 0 0 false false
  let r3 := reply "following" 0 0 false "solo" 3 4 true true
  (Status.parse r1).isSome
    && (Status.parse r1).map (·.holds m) == some true
    && (Status.parse r1).map (·.holds solo) == some false
    && (Status.parse r3).map (·.holds solo) == some true
    && (Status.parse r3).map (·.holds m) == some false
    && (Status.parse r1).map (·.floorIs m) == some true
    && (Status.parse r2).map (·.remainingMs) == some 5000
    && (Status.parse r2).map (·.state) == some "preparing"
    -- a reply cut short, an error reply, a missing field: Unknown, never a default
    && (Status.parse (r1.replace "END\r\n" "")).isNone
    && (Status.parse "SERVER_ERROR write authority is off\r\n").isNone
    && (Status.parse (r1.replace "STAT floor_gen 4\r\n" "")).isNone
    -- an undetermined identity ("-") is Unknown (fail closed); a membership bound to another copy is not held
    && (Status.parse (r1.replace "STAT identity_copy c1" "STAT identity_copy -")).isNone
    && (Status.parse (r1.replace "STAT identity_boot b1" "STAT identity_boot -")).isNone
    && (Status.parse (r1.replace "STAT members_copy c1" "STAT members_copy c0")).map (·.holds m) == some false
    && (Status.parse (r1.replace "STAT grant_gen 4" "STAT grant_gen 9")).map (·.holds m) == some false
    && (Status.parse (r1.replace "promise_remaining_ms 0" "promise_remaining_ms x")).isNone

def tCmds : Bool :=
  let sc : WireScope := { id := 7, termNext := 3, gen := 4, boot := "b1", copy := "c1" }
  let c : Config := { ttlMs := 10000, renewMs := 3000, marginMs := 2000, prepareTimeoutMs := 60000 }
  cmdMembers 0 (mem 2 5 "a" ["b:1", "c:1"]) c == "authority members 0 2 5 10000 3000 b:1 c:1"
    && cmdMembers 1 (mem 2 5 "a" []) c == "authority solo 1 2 5"
    && cmdFloor 0 (mem 2 5 "a" ["b"]) == "authority floor 0 2 0"
    && cmdPrepare 0 sc == "authority prepare 0 7 3 4 b1 c1"
    && cmdCommit 0 sc == "authority commit 0 7 3 4 b1 c1"
    && cmdCancel 0 sc == "authority cancel 0 7 3 4 b1 c1"
    && cmdStatus 2 == "authority status 2"

def rep (state : String) (intent remaining : Nat) (promotable : Bool) : Option Replica :=
  some { state, intent, scopeOk := true, remainingMs := remaining, promotable }

def tDecide : Bool :=
  gateDecide false true .none none 1 == .abort "the candidate is not in the membership"
    && gateDecide true false .none none 1 == .wait "the master has not confirmed this membership"
    && gateDecide true true .none none 0 == .createIntent
    && gateDecide true true .cancelled none 3 == .createIntent
    -- the cancel is in the store but the successor still holds that prepare: say it again, do not start a new attempt over it
    && gateDecide true true .cancelled (rep "preparing" 3 0 false) 3 == .sendCancel
    && gateDecide true true .cancelled (rep "following" 0 0 false) 3 == .createIntent
    && gateDecide true true .cancelled (rep "preparing" 2 0 false) 3 == .createIntent
    && gateDecide true true (.pending false false) none 1 == .sendPrepare
    && gateDecide true true (.pending true true) (rep "preparing" 1 0 false) 1 == .cancelCas "the prepare window passed without a commit"
    -- unknown never decides
    && gateDecide true true (.pending true false) none 1 == .wait "the successor is unreadable"
    && gateDecide true true .committed none 1 == .wait "the successor is unreadable"
    -- the successor lost the prepare (restart): cancel, so a new attempt can be made
    && (match gateDecide true true (.pending true false) (rep "following" 0 0 false) 1 with | .cancelCas _ => true | _ => false)
    && (match gateDecide true true (.pending true false) (rep "preparing" 2 0 false) 1 with | .cancelCas _ => true | _ => false)
    -- its promise to the old master is not over
    && (match gateDecide true true (.pending true false) (rep "preparing" 1 4000 false) 1 with | .wait _ => true | _ => false)
    && gateDecide true true (.pending true false) (rep "preparing" 1 0 false) 1 == .commitCas
    -- a prepare under another scope (term / generation / incarnation / copy) is not this attempt
    && (match gateDecide true true (.pending true false) (some { state := "preparing", intent := 1, scopeOk := false, remainingMs := 0, promotable := false }) 1 with | .cancelCas _ => true | _ => false)
    && (match gateDecide true true .committed (some { state := "committed", intent := 1, scopeOk := false, remainingMs := 0, promotable := true }) 1 with | .abort _ => true | _ => false)
    -- committed
    && gateDecide true true .committed (rep "committed" 1 0 true) 1 == .proceed
    && gateDecide true true .committed (rep "promoted" 1 0 true) 1 == .proceed
    && gateDecide true true .committed (rep "preparing" 1 0 false) 1 == .sendCommit
    && (match gateDecide true true .committed (rep "committed" 1 900 false) 1 with | .wait _ => true | _ => false)
    && (match gateDecide true true .committed (rep "following" 0 0 false) 1 with | .abort _ => true | _ => false)

/-- Exhaustive over a finite domain: what the gate may NOT do. -/
def tDecideSafety : Bool :=
  let ivs : List IntentView := [.none, .pending false false, .pending false true, .pending true false, .pending true true, .committed, .cancelled]
  let states := ["following", "preparing", "committed", "promoted"]
  let rvs : List (Option Replica) :=
    none :: (states.flatMap fun s => [0, 1, 2].flatMap fun i => [0, 5].flatMap fun r => [true, false].map fun p => some { state := s, intent := i, scopeOk := true, remainingMs := r, promotable := p })
  let all := [true, false].flatMap fun succ => [true, false].flatMap fun acked => ivs.flatMap fun iv => rvs.map fun rv => (succ, acked, iv, rv)
  all.all fun (succ, acked, iv, rv) =>
    let id := 1
    let a := gateDecide succ acked iv rv id
    -- nothing happens for a non-successor or an unconfirmed membership
    (if (!succ || !acked) then (match a with | .wait _ | .abort _ => true | _ => false) else true)
    -- a commit only on a prepared, unexpired intent whose successor shows PREPARING of it with nothing left to wait
    && (match a with
        | .commitCas =>
          succ && acked && iv == .pending true false &&
            (match rv with | some r => r.state == "preparing" && r.intent == id && r.remainingMs == 0 | none => false)
        | _ => true)
    -- proceed only for a committed intent that the successor says it can be promoted on
    && (match a with
        | .proceed => iv == .committed && (match rv with | some r => r.promotable && r.intent == id | none => false)
        | _ => true)
    -- a committed intent is never cancelled; an unreadable successor never commits or proceeds
    && (match a with | .cancelCas _ => iv != .committed | _ => true)
    && (match a with | .sendCancel => iv == .cancelled | _ => true)
    && (if rv.isNone then (match a with | .commitCas | .proceed | .sendCommit => false | _ => true) else true)


/-! ### fence-by-member promotion of the sole same-history lagging copy -/

open FlareOperator.PromotionEvidence in
def tRoute : Bool :=
  let forb : Class := .forbidden "rejoining"
  let unk : Class := .unknown "the last master's history was not recorded"
  -- only "lagging (same history)", read this pass, with no promotable record member
  nonMemberRoute (some .lagging) true [] == .soleLagging
    && nonMemberRoute (some .lagging) true [unk, forb] == .soleLagging
    -- (b) any other evidence of the candidate keeps today's abort
    && nonMemberRoute (some forb) true [] == .refuse
    && nonMemberRoute (some unk) true [] == .refuse
    && nonMemberRoute (some .eligible) true [] == .refuse
    && nonMemberRoute (some .legacy) true [] == .refuse
    && nonMemberRoute (some .empty) true [] == .refuse
    && nonMemberRoute none true [] == .refuse
    -- (c) a record member that can be promoted: the non-member is never chosen
    && nonMemberRoute (some .lagging) true [.eligible] == .refuse
    && nonMemberRoute (some .lagging) true [unk, .lagging] == .refuse
    && nonMemberRoute (some .lagging) true [.empty] == .refuse
    && nonMemberRoute (some .lagging) true [.legacy, forb] == .refuse
    -- evidence not read on this pass is no evidence
    && nonMemberRoute (some .lagging) false [] == .refuse
    -- the fence: the smallest readable member key, never the candidate
    && chooseFence ["b:1", "a:1", "c:1"] ["c:1", "b:1"] "x:1" == some "b:1"
    && chooseFence ["b:1", "a:1"] ["a:1", "b:1"] "a:1" == some "b:1"
    && chooseFence ["b:1", "a:1"] [] "x:1" == none
    && chooseFence [] ["a:1"] "x:1" == none

def fv (member : Bool) (state : String) (intent remaining : Nat) (scopeOk floorReached : Bool) : Option FenceView :=
  some { member, rep := some { state, intent, scopeOk, remainingMs := remaining, promotable := false }, floorReached }

def tFenceDecide : Bool :=
  let route := NonMemberRoute.soleLagging
  let d := fun iv rv fvw avail acked => gateDecide false acked iv rv 1 route fvw avail
  -- (b) without the route the non-member is refused, whatever else is in place
  gateDecide false true (.pending true false) (rep "preparing" 1 0 false) 1 .refuse (fv true "preparing" 1 0 true false) true
      == .abort "the candidate is not in the membership"
    -- (d) the record is not acked: wait, nothing else
    && d .none none none true false == .wait "the master has not confirmed this membership"
    && d (.pending true false) (rep "preparing" 1 0 false) (fv true "preparing" 1 0 true false) true false
        == .wait "the master has not confirmed this membership"
    -- no readable member to be the fence: wait; one: create the intent (it names the fence)
    && (match d .none none none false true with | .wait _ => true | _ => false)
    && d .none none none true true == .createIntent
    && d (.pending false false) none none true true == .sendPrepare
    -- the commit: candidate AND fence prepare this intent, the fence in the membership, its promise expired
    && d (.pending true false) (rep "preparing" 1 0 false) (fv true "preparing" 1 0 true false) true true == .commitCas
    -- never earlier than the fence's promise end + margin
    && (match d (.pending true false) (rep "preparing" 1 0 false) (fv true "preparing" 1 4000 true false) true true with | .wait _ => true | _ => false)
    -- (e) the fence's scope changed (copy swap / restart: state following or another scope): cancel, no commit
    && (match d (.pending true false) (rep "preparing" 1 0 false) (fv true "following" 0 0 true false) true true with | .cancelCas _ => true | _ => false)
    && (match d (.pending true false) (rep "preparing" 1 0 false) (fv true "preparing" 1 0 false false) true true with | .cancelCas _ => true | _ => false)
    && (match d (.pending true false) (rep "preparing" 2 0 false) (fv true "preparing" 1 0 true false) true true with | .cancelCas _ => true | _ => false)
    -- the candidate's scope changed
    && (match d (.pending true false) (rep "following" 0 0 false) (fv true "preparing" 1 0 true false) true true with | .cancelCas _ => true | _ => false)
    -- the fence is not (any more) in the membership: cancel (the commit CAS would refuse it too)
    && (match d (.pending true false) (rep "preparing" 1 0 false) (fv false "preparing" 1 0 true false) true true with | .cancelCas _ => true | _ => false)
    -- unreadable: wait, never commit
    && (match d (.pending true false) none (fv true "preparing" 1 0 true false) true true with | .wait _ => true | _ => false)
    && (match d (.pending true false) (rep "preparing" 1 0 false) none true true with | .wait _ => true | _ => false)
    && (match d (.pending true false) (rep "preparing" 1 0 false) (some { member := true, rep := none, floorReached := false }) true true with | .wait _ => true | _ => false)
    && d (.pending true true) (rep "preparing" 1 0 false) (fv true "preparing" 1 0 true false) true true == .cancelCas "the prepare window passed without a commit"
    -- cancelled: both are told again while either still prepares; a new attempt only when neither does
    && d .cancelled (rep "preparing" 1 0 false) (fv true "following" 0 0 true false) true true == .sendCancel
    && d .cancelled (rep "following" 0 0 false) (fv true "preparing" 1 0 true false) true true == .sendCancel
    && d .cancelled (rep "following" 0 0 false) (fv true "following" 0 0 true false) true true == .createIntent
    && (match d .cancelled (rep "following" 0 0 false) (some { member := true, rep := none, floorReached := false }) true true with | .wait _ => true | _ => false)
    -- (f) committed: the commit goes to the candidate only after the fence's floor fences the old term
    && d .committed (rep "preparing" 1 0 false) (fv true "preparing" 1 0 true false) true true == .pushFloor
    && d .committed (rep "preparing" 1 0 false) (fv true "preparing" 1 0 true true) true true == .sendCommit
    && (match d .committed (rep "preparing" 1 0 false) (fv true "following" 0 0 true true) true true with | .abort _ => true | _ => false)
    && (match d .committed (rep "preparing" 1 0 false) (fv true "preparing" 2 0 true true) true true with | .abort _ => true | _ => false)
    && (match d .committed (rep "preparing" 1 0 false) (some { member := true, rep := none, floorReached := true }) true true with | .wait _ => true | _ => false)
    && d .committed (rep "committed" 1 0 true) (fv true "preparing" 1 0 true true) true true == .proceed
    -- a committed fenced intent is carried through even when the route is gone (a committed intent is not undone)
    && gateDecide false true .committed (rep "preparing" 1 0 false) 1 .refuse (fv true "preparing" 1 0 true true) false == .sendCommit
    -- a fence-less committed intent of a non-member is still aborted
    && gateDecide false true .committed (rep "preparing" 1 0 false) 1 .refuse none false == .abort "the candidate is not in the membership"

def tFenceRelease : Bool :=
  -- the fence is cancelled only when the record is at the new term AND its floor is
  fenceRelease 3 4 (some (true, true)) == .keep "the record has not moved to the new term yet"
    && fenceRelease 4 4 (some (true, false)) == .pushFloor
    && fenceRelease 4 4 (some (true, true)) == .cancel
    && fenceRelease 5 4 (some (true, true)) == .cancel
    && fenceRelease 5 4 (some (false, true)) == .done
    && fenceRelease 3 4 (some (false, false)) == .done
    && fenceRelease 4 4 none == .keep "the fence is unreadable"

/-- Exhaustive over a finite domain: the fence path commits / tells the candidate only under its conditions. -/
def tFenceSafety : Bool :=
  let ivs : List IntentView := [.none, .pending false false, .pending false true, .pending true false, .pending true true, .committed, .cancelled]
  let states := ["following", "preparing", "committed", "promoted"]
  let reps : List (Option Replica) :=
    none :: (states.flatMap fun s => [0, 1, 2].flatMap fun i => [0, 5].flatMap fun r => [true, false].flatMap fun ok =>
      [true, false].map fun p => some { state := s, intent := i, scopeOk := ok, remainingMs := r, promotable := p })
  let fvs : List (Option FenceView) :=
    none :: (reps.flatMap fun r => [true, false].flatMap fun m => [true, false].map fun f => some { member := m, rep := r, floorReached := f })
  let all := [true, false].flatMap fun acked => [true, false].flatMap fun av => ivs.flatMap fun iv => reps.flatMap fun rv => fvs.map fun f => (acked, av, iv, rv, f)
  all.all fun (acked, av, iv, rv, f) =>
    let a := gateDecide false acked iv rv 1 .soleLagging f av
    let holds : Option Replica → Bool := fun r => match r with | some x => x.holds 1 | none => false
    let fenceOf : Option FenceView → Option Replica := fun x => x.bind (·.rep)
    -- a commit CAS: pending and not expired, acked, the candidate and the fence both hold the prepare,
    -- the fence a member whose promise to the old master is over
    (match a with
      | .commitCas =>
        acked && iv == .pending true false && holds rv && holds (fenceOf f)
          && (f.map (·.member)) == some true && ((fenceOf f).map (·.remainingMs)) == some 0
      | _ => true)
    -- the commit message to the candidate: only with the fence still preparing and its floor fencing the old term
    && (match a with
        | .sendCommit => acked && iv == .committed && holds (fenceOf f) && (f.map (·.floorReached)) == some true && rv.isSome
        | _ => true)
    && (match a with | .pushFloor => iv == .committed && holds (fenceOf f) && (f.map (·.floorReached)) == some false | _ => true)
    -- nothing at all happens on an unconfirmed record
    && (if !acked then (match a with | .wait _ | .abort _ => true | _ => false) else true)
    -- a committed intent is never cancelled; unreadable never commits
    && (match a with | .cancelCas _ => iv != .committed | _ => true)
    && (if rv.isNone || (fenceOf f).isNone then (match a with | .commitCas | .sendCommit | .pushFloor => false | _ => true) else true)
    && (if rv.isNone then (match a with | .proceed => false | _ => true) else true)
    -- a new attempt only when no cancel is outstanding on either node
    && (match a with | .createIntent => iv == .none || (iv == .cancelled && !holds rv && !holds (fenceOf f)) | _ => true)

def checks : List (String × Bool) :=
  [ ("write authority: every number explicit and consistent, else OFF", tConfig),
    ("write authority: membership record round trip, strict decode", tCodec),
    ("write authority: membership transitions (term only with a committed intent, frozen by an open intent, fail closed)", tNext),
    ("write authority: flared status parse (Unknown on a cut-short / missing / error reply), holds / floor", tStatus),
    ("write authority: command lines", tCmds),
    ("write authority: the gate's decision per state", tDecide),
    ("write authority: the gate never commits / proceeds / cancels outside its conditions (exhaustive over the domain)", tDecideSafety),
    ("fence: the route to a non-member is only 'sole same-history lagging copy' read this pass with no promotable member; the fence is the smallest readable member", tRoute),
    ("fence: the gate's decision on the fence path (acked, commit only after the fence's promise expired, scope change cancels both, commit message only after the floor, committed carried through)", tFenceDecide),
    ("fence: release after the record moved to the new term and the fence's floor fences it", tFenceRelease),
    ("fence: the fence path never commits / tells the candidate / pushes the floor outside its conditions (exhaustive over the domain)", tFenceSafety) ]

end FlareOperator.WriteAuthorityChecks
