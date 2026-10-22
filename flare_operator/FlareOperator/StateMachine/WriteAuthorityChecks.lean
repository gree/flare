/-
  WriteAuthorityChecks.lean — unit checks of the pure part of the C' wiring
  (WriteAuthority): config, membership record and its transitions, flared's
  status reply, and the gate's decision (exhaustive over a finite domain).
-/
import FlareOperator.StateMachine.WriteAuthority

namespace FlareOperator.WriteAuthorityChecks

open FlareOperator.WriteAuthority

def mem (term gen : Nat) (master : String) (succ : List String) (acked := false) : Members :=
  { term, gen, master, successors := succ, acked }

def reply (state : String) (intent remaining : Nat) (promotable : Bool) (mode : String) (mt mg : Nat)
    (grant solo : Bool) : String :=
  let b : Bool → String := fun x => if x then "1" else "0"
  s!"STAT authority_enabled 1\r\nSTAT authority_refused 0\r\nSTAT promise_state {state}\r\nSTAT promise_intent {intent}\r\nSTAT promise_have 1\r\nSTAT promise_remaining_ms {remaining}\r\nSTAT promise_promotable {b promotable}\r\nSTAT floor_term 3\r\nSTAT floor_gen 4\r\nSTAT floor_set 1\r\nSTAT members_mode {mode}\r\nSTAT members_term {mt}\r\nSTAT members_gen {mg}\r\nSTAT members_successors -\r\nSTAT grant_valid {b grant}\r\nSTAT grant_term 3\r\nSTAT grant_gen 4\r\nSTAT grant_solo {b solo}\r\nSTAT grant_remaining_ms 0\r\nEND\r\n"

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
  let m := mem 3 7 "n-0.x.svc:12121" ["n-1.x.svc:12121", "n-2.x.svc:12121"] true
  let solo := mem 1 1 "n-0.x.svc:12121" []
  Members.decode m.encode == some m
    && Members.decode solo.encode == some solo
    && (Members.decode "v=1 term=03 gen=1 acked=0 master=a succ=").isNone
    && (Members.decode "v=2 term=3 gen=1 acked=0 master=a succ=").isNone
    && (Members.decode "v=1 gen=1 term=3 acked=0 master=a succ=").isNone
    && (Members.decode "v=1 term=3 gen=1 acked=2 master=a succ=").isNone
    && (Members.decode "v=1 term=3 gen=1 acked=0 master= succ=").isNone
    && (Members.decode "v=1 term=3 gen=1 acked=0 master=a succ=b,,c").isNone
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
    -- losing the only successor: solo, a new generation
    && Members.next (some o) (v1 (some a) []) false none == some (mem 2 6 a [])
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
    && (Status.parse (r1.replace "promise_remaining_ms 0" "promise_remaining_ms x")).isNone

def tCmds : Bool :=
  let c : Config := { ttlMs := 10000, renewMs := 3000, marginMs := 2000, prepareTimeoutMs := 60000 }
  cmdMembers 0 (mem 2 5 "a" ["b:1", "c:1"]) c == "authority members 0 2 5 10000 3000 b:1 c:1"
    && cmdMembers 1 (mem 2 5 "a" []) c == "authority solo 1 2 5"
    && cmdFloor 0 (mem 2 5 "a" ["b"]) == "authority floor 0 2 0"
    && cmdPrepare 0 7 3 == "authority prepare 0 7 3"
    && cmdCommit 0 7 == "authority commit 0 7"
    && cmdCancel 0 7 == "authority cancel 0 7"
    && cmdStatus 2 == "authority status 2"

def rep (state : String) (intent remaining : Nat) (promotable : Bool) : Option Replica :=
  some { state, intent, remainingMs := remaining, promotable }

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
    && gateDecide true true (.pending true false) (rep "following" 0 0 false) 1 == .cancelCas "the successor does not hold this prepare"
    && gateDecide true true (.pending true false) (rep "preparing" 2 0 false) 1 == .cancelCas "the successor does not hold this prepare"
    -- its promise to the old master is not over
    && (match gateDecide true true (.pending true false) (rep "preparing" 1 4000 false) 1 with | .wait _ => true | _ => false)
    && gateDecide true true (.pending true false) (rep "preparing" 1 0 false) 1 == .commitCas
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
    none :: (states.flatMap fun s => [0, 1, 2].flatMap fun i => [0, 5].flatMap fun r => [true, false].map fun p => some { state := s, intent := i, remainingMs := r, promotable := p })
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

def checks : List (String × Bool) :=
  [ ("write authority: every number explicit and consistent, else OFF", tConfig),
    ("write authority: membership record round trip, strict decode", tCodec),
    ("write authority: membership transitions (term only with a committed intent, frozen by an open intent, fail closed)", tNext),
    ("write authority: flared status parse (Unknown on a cut-short / missing / error reply), holds / floor", tStatus),
    ("write authority: command lines", tCmds),
    ("write authority: the gate's decision per state", tDecide),
    ("write authority: the gate never commits / proceeds / cancels outside its conditions (exhaustive over the domain)", tDecideSafety) ]

end FlareOperator.WriteAuthorityChecks
