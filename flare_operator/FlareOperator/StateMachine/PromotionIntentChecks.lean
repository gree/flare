/-
  PromotionIntentChecks.lean — deterministic unit checks for PromotionIntent and
  PromotionRefusal (called from UnitTests.run). Finite schedules and concrete
  records: not a proof of arbitrary histories, clocks, membership changes or
  durable IO.
-/
import FlareOperator.StateMachine.PromotionIntent
import FlareOperator.StateMachine.PromotionRefusal

namespace FlareOperator.PromotionIntentChecks

open FlareOperator.PromotionIntent
open FlareOperator.PromotionRefusal

/-- intent 7 for "r1", leader 1, deadline 20, prepare acknowledged, old authority to 10 -/
def prepared : Intent :=
  match recordPrepared (Intent.prepare 7 0 "r1" 1 20) 7 1 10 with
  | .applied i => i
  | _ => Intent.prepare 7 0 "r1" 1 20

def committedAt (i : Intent) (now : Nat) : Intent :=
  (commit i 7 (.leader 1) now).next i

def cancelledByLeader (i : Intent) : Intent := (cancel i 7 (.leader 1) 0).next i

def preparingView : View :=
  onPrepared { identity := "r1" } 7 20

instance : BEq (Except DecodeError Intent) where
  beq a b := match a, b with
    | .ok x, .ok y => x == y
    | .error x, .error y => x == y
    | _, _ => false

def isOk {α : Type} : Except Why α → Bool
  | .ok _ => true
  | .error _ => false

def isErr (w : Why) {α : Type} : Except Why α → Bool
  | .error x => x == w
  | .ok _ => false

def refusedWith (o : Outcome) (r : Refusal) : Bool := o == .refused r

def isMalformed : Except DecodeError Intent → Bool
  | .error (.malformed _) => true
  | _ => false

def roundTrips (i : Intent) : Bool := decode (encode i) == .ok i

def checks : List (String × Bool) :=
  let c7 := committedAt prepared 19
  let x7 := cancelledByLeader prepared
  [
  -- the 0a3fff2 counterexample: commit at 19 < deadline 20, reply arrives at 22
  ("counterexample: commit at 19 (< deadline 20) is applied; the deadline timer at 20 only asks for the cancel CAS",
    c7.decision == .committed && c7.decidedBy == some 1 &&
    (let (v, acts) := onTimer preparingView 20
     v.role == .preparing && acts == [.tryCancel]))
  , ("counterexample: the timer's cancel CAS after the commit is refused (alreadyCommitted); the successor never resumes",
    refusedWith (cancel c7 7 .successor 20) .alreadyCommitted &&
    isErr .committedNeverResumes (mayResume preparingView (.present c7)))
  , ("counterexample: renewing promises to 40 while preparing is refused, localOldUntil stays 0",
    (let (v, ok) := renew preparingView 40
     !ok && v.localOldUntil == 0))
  , ("counterexample: the delayed commit read at 22 promotes safely (old authority ended at 10)",
    (let (v, acts) := onRead preparingView (.present c7) 22 0
     v.role == .promoted && acts == [.activate 22] && noOverlap v 10))
  , ("counterexample (rejected rule): if a timer had resumed promises to 40, the commit read at 22 is refused (oldAuthorityLive, promiseResumed)",
    (let following : View := { preparingView with role := .following }
     let (resumed, _) := renew following 40
     let back := { resumed with role := .preparing }
     isErr .oldAuthorityLive (mayPromote back (.present c7) 22 0) &&
     !(noOverlap { back with role := .promoted, activation := some 22 } 40)))
  -- the CAS races
  , ("race: cancel first -> a later commit is refused (alreadyCancelled), never applied",
    x7.decision == .cancelled && refusedWith (commit x7 7 (.leader 1) 12) .alreadyCancelled)
  , ("race: commit first -> a later leader cancel is refused (alreadyCommitted)",
    refusedWith (cancel c7 7 (.leader 1) 12) .alreadyCommitted)
  , ("race: successor timer cancel at the deadline wins over a commit attempt at the deadline (commit expired)",
    refusedWith (commit prepared 7 (.leader 1) 20) .expired &&
    ((cancel prepared 7 .successor 20).next prepared).decision == .cancelled)
  , ("race: the deadline is exclusive for the commit and inclusive for the successor cancel",
    ((commit prepared 7 (.leader 1) 19).next prepared).decision == .committed &&
    refusedWith (cancel prepared 7 .successor 19) .tooEarly)
  , ("race: the same decision twice is a noop returning the record",
    (commit c7 7 (.leader 1) 19) == .noop c7 && (cancel x7 7 (.leader 1) 5) == .noop x7 &&
    (cancel x7 7 .successor 25) == .noop x7)
  , ("race: duplicate commit with a stale token is refused",
    refusedWith (commit c7 7 (.leader 0) 19) .staleLeader)
  , ("race: terminal decisions never flip, over every actor/time sample",
    ([0, 5, 19, 20, 99].all fun t =>
      [Actor.successor, .leader 0, .leader 1, .leader 2].all fun a =>
        (cancel c7 7 a t).next c7 == c7 && (commit x7 7 a t).next x7 == x7))
  -- leader fencing
  , ("fence: an old leader's commit after a new leader adopted is refused (staleLeader)",
    (match adoptLeader prepared 2 with
     | .applied p2 => refusedWith (commit p2 7 (.leader 1) 12) .staleLeader &&
         ((commit p2 7 (.leader 2) 12).next p2).decision == .committed
     | _ => false))
  , ("fence: a leader that has not adopted (future token) cannot commit",
    refusedWith (commit prepared 7 (.leader 2) 12) .staleLeader)
  , ("fence: adopting an equal or older token is refused",
    adoptLeader prepared 1 == .refused .staleLeader && adoptLeader prepared 0 == .refused .staleLeader)
  , ("fence: a new leader keeps a committed decision and cannot cancel it",
    (match adoptLeader c7 2 with
     | .applied p2 => p2.decision == .committed && refusedWith (cancel p2 7 (.leader 2) 13) .alreadyCommitted
     | _ => false))
  , ("fence: a new leader keeps a cancelled decision and cannot commit it",
    (match adoptLeader x7 2 with
     | .applied p2 => p2.decision == .cancelled && refusedWith (commit p2 7 (.leader 2) 13) .alreadyCancelled
     | _ => false))
  , ("fence: the old leader's cancel after adoption is refused; the new leader's cancel applies",
    (match adoptLeader prepared 2 with
     | .applied p2 => refusedWith (cancel p2 7 (.leader 1) 5) .staleLeader &&
         ((cancel p2 7 (.leader 2) 5).next p2).decision == .cancelled
     | _ => false))
  , ("intent id: a late unprepare for intent 6 does not touch intent 7",
    refusedWith (cancel prepared 6 (.leader 1) 5) .staleIntent &&
    refusedWith (cancel prepared 6 .successor 25) .staleIntent &&
    refusedWith (commit prepared 6 (.leader 1) 5) .staleIntent)
  , ("commit needs the prepare acknowledged (oldUntil recorded)",
    refusedWith (commit (Intent.prepare 7 0 "r1" 1 20) 7 (.leader 1) 5) .notPrepared)
  , ("commit by the successor is refused (notLeader)",
    refusedWith (commit prepared 7 .successor 5) .notLeader)
  , ("a second prepare acknowledgement cannot change oldUntil",
    refusedWith (recordPrepared prepared 7 1 99) .notPrepared)
  -- successor refusal rules
  , ("resume: only the store's affirmative cancelled allows it",
    isOk (mayResume preparingView (.present x7)) &&
    isErr .pending (mayResume preparingView (.present prepared)) &&
    isErr .storeUnreachable (mayResume preparingView .unreachable) &&
    isErr .noRecord (mayResume preparingView .absent) &&
    isErr .recordUnreadable (mayResume preparingView (.malformed (.malformed "x"))))
  , ("Unknown: after the deadline an unreachable store keeps PREPARING (no resume, no promote, no action)",
    (let (v, acts) := onTimer preparingView 100
     let (v2, acts2) := onRead v .unreachable 101 0
     v2.role == .preparing && acts == [.tryCancel] && acts2 == [] &&
     isErr .storeUnreachable (mayPromote v .unreachable 101 0)))
  , ("resume: a cancelled record of another intent or another successor is refused",
    isErr .otherIntent (mayResume preparingView (.present { x7 with id := 8 })) &&
    isErr .otherSuccessor (mayResume preparingView (.present { x7 with successor := "r2" })))
  , ("resume: a following successor has nothing to resume",
    isErr .notPreparing (mayResume { preparingView with role := .following } (.present x7)))
  , ("resume via read: following again, promises can be renewed",
    (let (v, acts) := onRead preparingView (.present x7) 30 0
     let (_, ok) := renew v 60
     v.role == .following && acts == [.resumePromises] && ok))
  , ("promote: pending, cancelled, absent, unreadable, other intent/successor are refused",
    isErr .notCommitted (mayPromote preparingView (.present prepared) 50 0) &&
    isErr .unprepared (mayPromote preparingView (.present x7) 50 0) &&
    isErr .noRecord (mayPromote preparingView .absent 50 0) &&
    isErr .recordUnreadable (mayPromote preparingView (.malformed (.unknownVersion 9)) 50 0) &&
    isErr .otherIntent (mayPromote preparingView (.present { c7 with id := 8 }) 50 0) &&
    isErr .otherSuccessor (mayPromote preparingView (.present { c7 with successor := "r2" }) 50 0))
  , ("promote waits for the old authority end + margin on the successor's own clock",
    isErr .oldAuthorityLive (mayPromote preparingView (.present c7) 10 1) &&
    isOk (mayPromote preparingView (.present c7) 11 1) &&
    isErr .oldAuthorityLive (mayPromote preparingView (.present c7) 9 0) &&
    isOk (mayPromote preparingView (.present c7) 10 0))
  , ("promote: a duplicate commit delivery cannot re-promote or move the activation time",
    (let (v, _) := onRead preparingView (.present c7) 22 0
     let (v2, acts) := onRead v (.present c7) 30 0
     v2 == v && acts == [] && v2.activation == some 22))
  , ("prepare while already preparing/promoted is ignored",
    onPrepared preparingView 8 99 == preparingView)
  -- old master side
  , ("master: solo keeps serving at any time (no write stop just because it is alone)",
    !masterRefusesWrite .solo 0 0 && !masterRefusesWrite .solo 1000000 1000)
  , ("master: with a successor it refuses from authorityEnd - margin on its own clock",
    !masterRefusesWrite (.withSuccessor 100) 89 10 && masterRefusesWrite (.withSuccessor 100) 90 10 &&
    masterRefusesWrite (.withSuccessor 100) 100 0 && !masterRefusesWrite (.withSuccessor 100) 99 0)
  , ("master: fenced always refuses",
    masterRefusesWrite .fenced 0 0 && masterRefusesWrite (fence (.withSuccessor 100)) 0 0)
  , ("master: a late or wrong-nonce grant never extends the authority",
    acceptGrant (.withSuccessor 50) 3 3 10 40 30 == .withSuccessor 50 &&   -- now 40 < 10+30? 40 !< 40 -> discarded
    acceptGrant (.withSuccessor 50) 3 4 10 20 30 == .withSuccessor 50 &&
    acceptGrant (.withSuccessor 50) 3 3 10 20 30 == .withSuccessor 50 &&   -- end 40 < 50: max keeps 50
    acceptGrant (.withSuccessor 30) 3 3 10 20 30 == .withSuccessor 40 &&
    acceptGrant .solo 3 3 10 20 30 == .solo)
  , ("master: leaving solo only via approval; returning to solo only on a confirmed committed removal",
    approveSuccessor .solo 50 == .withSuccessor 50 &&
    membershipRemoved (.withSuccessor 50) false == .withSuccessor 50 &&
    membershipRemoved (.withSuccessor 50) true == .solo &&
    membershipRemoved .fenced true == .fenced)
  -- persistence
  , ("persist: round trip for pending, prepared, committed, cancelled (leader and successor decided)",
    roundTrips (Intent.prepare 7 0 "r1" 1 20) && roundTrips prepared && roundTrips c7 && roundTrips x7 &&
    roundTrips ((cancel prepared 7 .successor 25).next prepared))
  , ("persist: identities with tab, newline, space, %, unicode round trip",
    roundTrips { prepared with successor := "a b\tc\nd%e é日本" } && roundTrips { prepared with successor := "" })
  , ("persist: encoded form is one line without raw tabs inside fields",
    !(encode { prepared with successor := "a\nb" }).contains '\n' &&
    ((encode prepared).splitOn "\t").length == 10)
  , ("persist: unknown versions are refused as such (v=0, v=2, v=99)",
    (let e := encode prepared
     let swap (n : Nat) := (e.replace "v=1" s!"v={n}")
     decode (swap 2) == .error (.unknownVersion 2) && decode (swap 99) == .error (.unknownVersion 99) &&
     decode (swap 0) == .error (.unknownVersion 0)))
  , ("persist: malformed records are refused (empty, garbage, wrong magic, missing/extra field, bad number, bad decision)",
    (let e := encode prepared
     isMalformed (decode "") && isMalformed (decode "garbage") &&
     isMalformed (decode (e.replace "flare-promotion-intent" "flare-x")) &&
     isMalformed (decode (e ++ "\textra=1")) &&
     isMalformed (decode ("\t".intercalate ((e.splitOn "\t").take 9))) &&
     isMalformed (decode (e.replace "id=7" "id=x")) &&
     isMalformed (decode (e.replace "decision=pending" "decision=done")) &&
     isMalformed (decode (e.replace "v=1" "v=x"))))
  , ("persist: non-canonical spellings are refused (leading zero, plus sign, reordered fields, upper-case escape)",
    (let e := encode prepared
     let fields := e.splitOn "\t"
     isMalformed (decode (e.replace "id=7" "id=07")) &&
     isMalformed (decode (e.replace "id=7" "id=+7")) &&
     isMalformed (decode ("\t".intercalate (fields.take 2 ++ [fields[3]!, fields[2]!] ++ fields.drop 4))) &&
     isMalformed (decode ((encode { prepared with successor := "a b" }).replace "%20" "%2"))  &&
     isMalformed (decode ((encode { prepared with successor := "a\u007fb" }).replace "%7f" "%7F"))))
  , ("persist: a raw space in the identity field is refused",
    isMalformed (decode ((encode prepared).replace "successor=r1" "successor=r 1")))
  , ("persist: inconsistent records are refused (pending with decided_by, committed without old_until or decider)",
    (let e := encode prepared
     isMalformed (decode (e.replace "decided_by=-" "decided_by=1")) &&
     isMalformed (decode ((encode c7).replace "old_until=10" "old_until=-")) &&
     isMalformed (decode ((encode c7).replace "decided_by=1" "decided_by=-"))))
  , ("persist: readOf — unreachable, absent, present, malformed, unknown version are distinct; garbage is never absent",
    readOf none == .unreachable && readOf (some none) == .absent &&
    readOf (some (some (encode prepared))) == .present prepared &&
    readOf (some (some "")) == .malformed (.malformed "field count") &&
    readOf (some (some ((encode prepared).replace "v=1" "v=2"))) == .malformed (.unknownVersion 2))
  , ("persist: a malformed record never lets the successor resume or promote",
    (let rr := readOf (some (some "garbage"))
     isErr .recordUnreadable (mayResume preparingView rr) &&
     isErr .recordUnreadable (mayPromote preparingView rr 99 0) &&
     (onRead preparingView rr 99 0).1 == preparingView))
  ]

end FlareOperator.PromotionIntentChecks
