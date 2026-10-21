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

open FlareOperator.PromotionBinding

/-- clocks: the store S, the successor R (boot b1 and, after a restart, b2), the old master M -/
def cS : ClockId := { node := "store", boot := "s1" }
def cR : ClockId := { node := "r1", boot := "b1" }
def cR2 : ClockId := { node := "r1", boot := "b2" }
def cM : ClockId := { node := "m", boot := "m1" }
def atS (t : Nat) : At := { clock := cS, t }
def atR (t : Nat) : At := { clock := cR, t }
def atR2 (t : Nat) : At := { clock := cR2, t }
def atM (t : Nat) : At := { clock := cM, t }

def bindR : Binding := { podUid := "uid-r1", bootId := "boot-1", copyId := "copy-1" }
def scope0 : Scope := { cluster := "c", partition := 0, generation := 5 }
def ref7 : Ref := { scope := scope0, id := 7, successor := "r1", binding := bindR }
def members0 : Membership := { scope := scope0, members := ["m", "r1"] }

/-- intent 7 for "r1" (pod uid-r1), leader 1, deadline 20 on the store's clock,
    prepare acknowledged, old authority to 10 on R's clock -/
def prepared : Intent :=
  match recordPrepared (Intent.prepare ref7 1 (atS 20)) ref7 1 (atR 10) with
  | .applied i => i
  | _ => Intent.prepare ref7 1 (atS 20)

def committedAt (i : Intent) (now : Nat) : Intent :=
  (commit i ref7 (.leader 1) members0 (atS now)).next i

def cancelledByLeader (i : Intent) : Intent := (cancel i ref7 (.leader 1) (atS 0)).next i

def preparingView : View :=
  onPrepared (View.init "r1" bindR scope0 cR) ref7 0 20

/-- R's view after the intent was committed with old authority ending at 10 -/
def commitIn (i : Intent) (now : Nat) : Bool := (commit i ref7 (.leader 1) members0 (atS now)) matches .applied _

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

def roundTrips (i : Intent) : Bool := decode (encode i) == .ok i

def refusedWith (o : Outcome) (r : Refusal) : Bool := o == .refused r

def isMalformed : Except DecodeError Intent → Bool
  | .error (.malformed _) => true
  | _ => false

def mism (m : Mismatch) : Refusal := .mismatch m

def other (f : Ref → Ref) : Ref := f ref7

/-- every CAS refuses a ref that differs from the intent's own, with this reason -/
def allRefuse (r : Ref) (m : Mismatch) : Bool :=
  refusedWith (commit prepared r (.leader 1) members0 (atS 5)) (mism m) &&
  refusedWith (cancel prepared r (.leader 1) (atS 5)) (mism m) &&
  refusedWith (cancel prepared r .successor (atS 25)) (mism m) &&
  refusedWith (recordPrepared (Intent.prepare ref7 1 (atS 20)) r 1 (atR 10)) (mism m)

/-- the successor view that is NOT the intent's pod -/
def replacedView (b : Binding) : View :=
  onPrepared (View.init "r1" b scope0 cR) { ref7 with binding := b } 0 20

def c7 := committedAt prepared 19
def x7 := cancelledByLeader prepared

def checks : List (String × Bool) :=
  let r2Clock : ClockId := { node := "r2", boot := "b1" }
  [
  -- the 0a3fff2 counterexample: commit at 19 < deadline 20, reply arrives at 22
  ("counterexample: commit at 19 (< deadline 20) is applied; the deadline timer at 20 only asks for the cancel CAS",
    c7.decision == .committed && c7.decidedBy == some 1 &&
    (let (v, acts) := onTimer preparingView 20
     v.role == .preparing && acts == [.tryCancel]))
  , ("counterexample: the timer's cancel CAS after the commit is refused (alreadyCommitted); the successor never resumes",
    refusedWith (cancel c7 ref7 .successor (atS 20)) .alreadyCommitted &&
    isErr .committedNeverResumes (mayResume preparingView (.present c7)))
  , ("counterexample: renewing promises to 40 while preparing is refused, localOldUntil stays 0",
    (let (v, ok) := renew preparingView 0 40
     !ok && v.localOldUntil == atR 0))
  , ("counterexample: the delayed commit read at 22 promotes safely (old authority ended at 10 on R's clock)",
    (let (v, acts) := onRead preparingView (.present c7) members0 22 0
     v.role == .promoted && acts == [.activate (atR 22)] && noOverlap v (atR 10)))
  , ("counterexample (rejected rule): if a timer had resumed promises to 40, the commit read at 22 is refused (oldAuthorityLive)",
    (let following : View := { preparingView with role := .following }
     let (resumed, _) := renew following 0 40
     let back := { resumed with role := .preparing }
     isErr .oldAuthorityLive (mayPromote back (.present c7) members0 22 0) &&
     !(noOverlap { back with role := .promoted, activation := some (atR 22) } (atR 40))))
  -- time representation: clock origins
  , ("clock (a): a bound on another node's clock is never 'safe' — old Nat compare max 100 0 + 0 <= 500 says promote, the At model refuses (clockMismatch)",
    (let foreign : Intent := { c7 with oldUntil := some { clock := r2Clock, t := 100 } }
     max 100 0 + 0 ≤ 500 &&
     isErr .clockMismatch (mayPromote preparingView (.present foreign) members0 500 0)))
  , ("clock (a): the same node's bound of another boot is refused too (b1 -> b2)",
    (let foreign : Intent := { c7 with oldUntil := some (atR2 10) }
     isErr .clockMismatch (mayPromote preparingView (.present foreign) members0 500 0)))
  , ("clock (a): commit / successor cancel with a reading from another clock than the store's deadline are refused (clockMismatch)",
    refusedWith (commit prepared ref7 (.leader 1) members0 (atR 5)) .clockMismatch &&
    refusedWith (cancel prepared ref7 .successor (atR 99)) .clockMismatch &&
    refusedWith (commit prepared ref7 (.leader 1) members0 { clock := { cS with boot := "s2" }, t := 5 }) .clockMismatch)
  , ("clock: a window announced as a duration is bound on the receiver's own clock (recv 7 + d 30 = 37 on R)",
    At.fromRequest cR 7 30 == atR 37 && (At.reached? (atR 5) (atS 5)).isNone &&
    At.reached? (atS 20) (atS 20) == some true && At.reached? (atS 19) (atS 20) == some false)
  , ("clock (b): a restart — persisted localOldUntil of boot b1 is not misread; without onBoot the promote is refused",
    (let (v, _) := renew { preparingView with role := .following } 0 10
     let back := { v with role := .preparing, clock := cR2 }   -- restarted, persisted record not rebased
     isErr .clockMismatch (mayPromote back (.present { c7 with oldUntil := some (atR2 10) }) members0 50 0)))
  , ("clock (b): after onBoot the old promises end by bootAt + maxLease on the new clock; promote waits for it, and a store bound of boot b1 still refuses",
    (let v2 := onBoot preparingView cR2 0 100
     isErr .clockMismatch (mayPromote v2 (.present c7) members0 500 0) &&          -- c7.oldUntil is b1
     (let c7b : Intent := { c7 with oldUntil := some (atR2 10) }
      isErr .oldAuthorityLive (mayPromote v2 (.present c7b) members0 99 0) &&
      isOk (mayPromote v2 (.present c7b) members0 100 0))))
  , ("clock (b): a persisted deadline of an older boot cannot be compared; the timer only asks for the (safe) cancel TRY, never changes the role",
    (let v2 := onBoot preparingView cR2 0 100
     let (v3, acts) := onTimer v2 0
     v3.role == .preparing && acts == [.tryCancel]))
  , ("clock (b): a restarted old master (new boot) refuses to ACK until a fresh authority; an old-boot end is not compared",
    (let m := MasterMode.withSuccessor { scope := scope0, binding := bindR } (atM 100)
     !masterRefusesWrite m (atM 50) 0 &&
     masterRefusesWrite m { clock := { cM with boot := "m2" }, t := 5 } 0))
  -- the CAS races
  , ("race: cancel first -> a later commit is refused (alreadyCancelled), never applied",
    x7.decision == .cancelled && refusedWith (commit x7 ref7 (.leader 1) members0 (atS 12)) .alreadyCancelled)
  , ("race: commit first -> a later leader cancel is refused (alreadyCommitted)",
    refusedWith (cancel c7 ref7 (.leader 1) (atS 12)) .alreadyCommitted)
  , ("race: successor timer cancel at the deadline wins over a commit attempt at the deadline (commit expired)",
    refusedWith (commit prepared ref7 (.leader 1) members0 (atS 20)) .expired &&
    ((cancel prepared ref7 .successor (atS 20)).next prepared).decision == .cancelled)
  , ("race: the deadline is exclusive for the commit and inclusive for the successor cancel",
    commitIn prepared 19 && refusedWith (cancel prepared ref7 .successor (atS 19)) .tooEarly)
  , ("race: the same decision twice is a noop returning the record",
    (commit c7 ref7 (.leader 1) members0 (atS 19)) == .noop c7 && (cancel x7 ref7 (.leader 1) (atS 5)) == .noop x7 &&
    (cancel x7 ref7 .successor (atS 25)) == .noop x7)
  , ("race: duplicate commit with a stale token is refused",
    refusedWith (commit c7 ref7 (.leader 0) members0 (atS 19)) .staleLeader)
  , ("race: terminal decisions never flip, over every actor/time sample",
    ([0, 5, 19, 20, 99].all fun t =>
      [Actor.successor, .leader 0, .leader 1, .leader 2].all fun a =>
        (cancel c7 ref7 a (atS t)).next c7 == c7 && (commit x7 ref7 a members0 (atS t)).next x7 == x7))
  -- leader fencing
  , ("fence: an old leader's commit after a new leader adopted is refused (staleLeader)",
    (match adoptLeader prepared 2 with
     | .applied p2 => refusedWith (commit p2 ref7 (.leader 1) members0 (atS 12)) .staleLeader &&
         ((commit p2 ref7 (.leader 2) members0 (atS 12)).next p2).decision == .committed
     | _ => false))
  , ("fence: a leader that has not adopted (future token) cannot commit",
    refusedWith (commit prepared ref7 (.leader 2) members0 (atS 12)) .staleLeader)
  , ("fence: adopting an equal or older token is refused",
    adoptLeader prepared 1 == .refused .staleLeader && adoptLeader prepared 0 == .refused .staleLeader)
  , ("fence: a new leader keeps a committed decision and cannot cancel it",
    (match adoptLeader c7 2 with
     | .applied p2 => p2.decision == .committed && refusedWith (cancel p2 ref7 (.leader 2) (atS 13)) .alreadyCommitted
     | _ => false))
  , ("fence: a new leader keeps a cancelled decision and cannot commit it",
    (match adoptLeader x7 2 with
     | .applied p2 => p2.decision == .cancelled && refusedWith (commit p2 ref7 (.leader 2) members0 (atS 13)) .alreadyCancelled
     | _ => false))
  , ("fence: the old leader's cancel after adoption is refused; the new leader's cancel applies",
    (match adoptLeader prepared 2 with
     | .applied p2 => refusedWith (cancel p2 ref7 (.leader 1) (atS 5)) .staleLeader &&
         ((cancel p2 ref7 (.leader 2) (atS 5)).next p2).decision == .cancelled
     | _ => false))
  , ("commit needs the prepare acknowledged (oldUntil recorded)",
    refusedWith (commit (Intent.prepare ref7 1 (atS 20)) ref7 (.leader 1) members0 (atS 5)) .notPrepared)
  , ("commit by the successor is refused (notLeader)",
    refusedWith (commit prepared ref7 .successor members0 (atS 5)) .notLeader)
  , ("a second prepare acknowledgement cannot change oldUntil",
    refusedWith (recordPrepared prepared ref7 1 (atR 99)) .notPrepared)
  -- exact binding: every CAS and every read refuses
  , ("binding: a late unprepare for intent 6 does not touch intent 7 (stale intent id)",
    allRefuse { ref7 with id := 6 } .staleIntent)
  , ("binding: the same-name pod replaced (other pod uid / flared boot / copy id) is refused by every CAS",
    allRefuse (other fun r => { r with binding := { bindR with podUid := "uid-r1b" } }) .wrongBinding &&
    allRefuse (other fun r => { r with binding := { bindR with bootId := "boot-2" } }) .wrongBinding &&
    allRefuse (other fun r => { r with binding := { bindR with copyId := "copy-2" } }) .wrongBinding)
  , ("binding: another successor name is refused",
    allRefuse { ref7 with successor := "r2" } .wrongSuccessor)
  , ("binding: another partition or another cluster is refused",
    allRefuse (other fun r => { r with scope := { scope0 with partition := 1 } }) .wrongScope &&
    allRefuse (other fun r => { r with scope := { scope0 with cluster := "d" } }) .wrongScope)
  , ("binding: a stale (or future) membership generation is refused",
    allRefuse (other fun r => { r with scope := { scope0 with generation := 4 } }) .staleGeneration &&
    allRefuse (other fun r => { r with scope := { scope0 with generation := 6 } }) .staleGeneration)
  , ("binding: a successor removed from the membership cannot be committed (notMember); the intent stays pending",
    refusedWith (commit prepared ref7 (.leader 1) { members0 with members := ["m"] } (atS 5)) (mism .notMember) &&
    refusedWith (commit prepared ref7 (.leader 1) { members0 with scope := { scope0 with generation := 6 } } (atS 5)) (mism .staleGeneration) &&
    refusedWith (commit prepared ref7 (.leader 1) { members0 with scope := { scope0 with partition := 1 } } (atS 5)) (mism .wrongScope))
  , ("binding: the replacement pod (same name, other uid) neither resumes nor promotes on the old pod's record",
    (let nv := replacedView { bindR with podUid := "uid-r1b" }
     nv.role == .preparing &&
     isErr (.mismatch .wrongBinding) (mayResume nv (.present x7)) &&
     isErr (.mismatch .wrongBinding) (mayPromote nv (.present c7) members0 99 0) &&
     (onRead nv (.present c7) members0 99 0).1 == nv))
  , ("binding: a prepare addressed to another pod / scope is ignored by the successor",
    onPrepared (View.init "r1" bindR scope0 cR) { ref7 with binding := { bindR with podUid := "uid-x" } } 0 20 == View.init "r1" bindR scope0 cR &&
    onPrepared (View.init "r1" bindR scope0 cR) { ref7 with scope := { scope0 with partition := 3 } } 0 20 == View.init "r1" bindR scope0 cR)
  , ("binding: a successor in another partition / cluster / generation refuses the record",
    (let inScope (sc : Scope) : View :=
       onPrepared (View.init "r1" bindR sc cR) { ref7 with scope := sc } 0 20
     isErr (.mismatch .wrongScope) (mayPromote (inScope { scope0 with partition := 1 }) (.present c7) members0 99 0) &&
     isErr (.mismatch .wrongScope) (mayResume (inScope { scope0 with cluster := "d" }) (.present x7)) &&
     isErr (.mismatch .staleGeneration) (mayResume (inScope { scope0 with generation := 6 }) (.present x7))))
  , ("binding: promotion is refused once the successor left the membership or the generation moved",
    isErr (.mismatch .notMember) (mayPromote preparingView (.present c7) { members0 with members := ["m"] } 99 0) &&
    isErr (.mismatch .staleGeneration) (mayPromote preparingView (.present c7) { members0 with scope := { scope0 with generation := 6 } } 99 0) &&
    (onRead preparingView (.present c7) { members0 with members := [] } 99 0).1 == preparingView)
  , ("binding: a grant from another peer (other pod uid / generation) never extends the old master's authority",
    (let peer : Peer := { scope := scope0, binding := bindR }
     let m := MasterMode.withSuccessor peer (atM 30)
     acceptGrant m { peer with binding := { bindR with podUid := "uid-r1b" } } 3 3 (atM 10) (atM 20) 30 == m &&
     acceptGrant m { peer with scope := { scope0 with generation := 6 } } 3 3 (atM 10) (atM 20) 30 == m &&
     acceptGrant m peer 3 3 (atM 10) (atM 20) 30 == .withSuccessor peer (atM 40)))
  -- successor refusal rules
  , ("resume: only the store's affirmative cancelled allows it",
    isOk (mayResume preparingView (.present x7)) &&
    isErr .pending (mayResume preparingView (.present prepared)) &&
    isErr .storeUnreachable (mayResume preparingView .unreachable) &&
    isErr .noRecord (mayResume preparingView .absent) &&
    isErr .recordUnreadable (mayResume preparingView (.malformed (.malformed "x"))))
  , ("Unknown: after the deadline an unreachable store keeps PREPARING (no resume, no promote, no action)",
    (let (v, acts) := onTimer preparingView 100
     let (v2, acts2) := onRead v .unreachable members0 101 0
     v2.role == .preparing && acts == [.tryCancel] && acts2 == [] &&
     isErr .storeUnreachable (mayPromote v .unreachable members0 101 0)))
  , ("resume: a following successor has nothing to resume",
    isErr .notPreparing (mayResume { preparingView with role := .following } (.present x7)))
  , ("resume via read: following again, promises can be renewed",
    (let (v, acts) := onRead preparingView (.present x7) members0 30 0
     let (_, ok) := renew v 30 30
     v.role == .following && acts == [.resumePromises] && ok))
  , ("promote: pending, cancelled, absent, unreadable are refused",
    isErr .notCommitted (mayPromote preparingView (.present prepared) members0 50 0) &&
    isErr .unprepared (mayPromote preparingView (.present x7) members0 50 0) &&
    isErr .noRecord (mayPromote preparingView .absent members0 50 0) &&
    isErr .recordUnreadable (mayPromote preparingView (.malformed (.unknownVersion 9)) members0 50 0))
  , ("promote waits for the old authority end + margin on the successor's own clock",
    isErr .oldAuthorityLive (mayPromote preparingView (.present c7) members0 10 1) &&
    isOk (mayPromote preparingView (.present c7) members0 11 1) &&
    isErr .oldAuthorityLive (mayPromote preparingView (.present c7) members0 9 0) &&
    isOk (mayPromote preparingView (.present c7) members0 10 0))
  , ("promote: a duplicate commit delivery cannot re-promote or move the activation time",
    (let (v, _) := onRead preparingView (.present c7) members0 22 0
     let (v2, acts) := onRead v (.present c7) members0 30 0
     v2 == v && acts == [] && v2.activation == some (atR 22)))
  , ("prepare while already preparing/promoted is ignored",
    onPrepared preparingView { ref7 with id := 8 } 0 99 == preparingView)
  -- old master side
  , ("master: solo keeps serving at any time (no write stop just because it is alone)",
    !masterRefusesWrite .solo (atM 0) 0 && !masterRefusesWrite .solo (atM 1000000) 1000)
  , ("master: with a successor it refuses from authorityEnd - margin on its own clock",
    (let p : Peer := { scope := scope0, binding := bindR }
     !masterRefusesWrite (.withSuccessor p (atM 100)) (atM 89) 10 && masterRefusesWrite (.withSuccessor p (atM 100)) (atM 90) 10 &&
     masterRefusesWrite (.withSuccessor p (atM 100)) (atM 100) 0 && !masterRefusesWrite (.withSuccessor p (atM 100)) (atM 99) 0))
  , ("master: fenced always refuses",
    masterRefusesWrite .fenced (atM 0) 0 && masterRefusesWrite (fence .solo) (atM 0) 0)
  , ("master: a late or wrong-nonce grant never extends the authority",
    (let p : Peer := { scope := scope0, binding := bindR }
     acceptGrant (.withSuccessor p (atM 50)) p 3 3 (atM 10) (atM 40) 30 == .withSuccessor p (atM 50) &&
     acceptGrant (.withSuccessor p (atM 50)) p 3 4 (atM 10) (atM 20) 30 == .withSuccessor p (atM 50) &&
     acceptGrant (.withSuccessor p (atM 50)) p 3 3 (atM 10) (atM 20) 30 == .withSuccessor p (atM 50) &&
     acceptGrant (.withSuccessor p (atM 30)) p 3 3 (atM 10) (atM 20) 30 == .withSuccessor p (atM 40) &&
     acceptGrant (.withSuccessor p (atM 30)) p 3 3 (atM 10) (atR 20) 30 == .withSuccessor p (atM 30) &&
     acceptGrant .solo p 3 3 (atM 10) (atM 20) 30 == .solo))
  , ("master: leaving solo only via approval; returning to solo only on a confirmed committed removal",
    (let p : Peer := { scope := scope0, binding := bindR }
     approveSuccessor .solo p (atM 50) == .withSuccessor p (atM 50) &&
     membershipRemoved (.withSuccessor p (atM 50)) false == .withSuccessor p (atM 50) &&
     membershipRemoved (.withSuccessor p (atM 50)) true == .solo &&
     membershipRemoved .fenced true == .fenced))
  -- persistence (codec only)
  , ("persist: round trip for pending, prepared, committed, cancelled (leader and successor decided)",
    roundTrips (Intent.prepare ref7 1 (atS 20)) && roundTrips prepared && roundTrips c7 && roundTrips x7 &&
    roundTrips ((cancel prepared ref7 .successor (atS 25)).next prepared))
  , ("persist: identities / binding / clock ids with tab, newline, space, %, colon, unicode round trip",
    roundTrips { prepared with successor := "a b\tc\nd%e é日本" } && roundTrips { prepared with successor := "" } &&
    roundTrips { prepared with binding := { podUid := "u:1 2", bootId := "b%", copyId := "" },
                               scope := { scope0 with cluster := "c:d e" },
                               deadline := { clock := { node := "n:1", boot := "b 1" }, t := 3 },
                               oldUntil := some { clock := { node := "", boot := "x\ty" }, t := 0 } })
  , ("persist: encoded form is one line, 15 tab separated fields",
    !(encode { prepared with successor := "a\nb" }).contains '\n' &&
    ((encode prepared).splitOn "\t").length == 15)
  , ("persist: unknown versions are refused as such (v=0, v=1, v=3, v=99)",
    (let e := encode prepared
     let swap (n : Nat) := (e.replace "v=2" s!"v={n}")
     decode (swap 1) == .error (.unknownVersion 1) && decode (swap 3) == .error (.unknownVersion 3) &&
     decode (swap 99) == .error (.unknownVersion 99) && decode (swap 0) == .error (.unknownVersion 0)))
  , ("persist: malformed records are refused (empty, garbage, wrong magic, missing/extra field, bad number, bad decision, bad clock)",
    (let e := encode prepared
     isMalformed (decode "") && isMalformed (decode "garbage") &&
     isMalformed (decode (e.replace "flare-promotion-intent" "flare-x")) &&
     isMalformed (decode (e ++ "\textra=1")) &&
     isMalformed (decode ("\t".intercalate ((e.splitOn "\t").take 9))) &&
     isMalformed (decode (e.replace "id=7" "id=x")) &&
     isMalformed (decode (e.replace "decision=pending" "decision=done")) &&
     isMalformed (decode (e.replace "deadline=store:s1:20" "deadline=store:20")) &&
     isMalformed (decode (e.replace "v=2" "v=x"))))
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
     isMalformed (decode ((encode c7).replace "old_until=r1:b1:10" "old_until=-")) &&
     isMalformed (decode ((encode c7).replace "decided_by=1" "decided_by=-"))))
  , ("persist: readOf — unreachable, absent, present, malformed, unknown version are distinct; garbage is never absent",
    readOf none == .unreachable && readOf (some none) == .absent &&
    readOf (some (some (encode prepared))) == .present prepared &&
    readOf (some (some "")) == .malformed (.malformed "field count") &&
    readOf (some (some ((encode prepared).replace "v=2" "v=3"))) == .malformed (.unknownVersion 3))
  , ("persist: a malformed record never lets the successor resume or promote",
    (let rr := readOf (some (some "garbage"))
     isErr .recordUnreadable (mayResume preparingView rr) &&
     isErr .recordUnreadable (mayPromote preparingView rr members0 99 0) &&
     (onRead preparingView rr members0 99 0).1 == preparingView))
  ]

end FlareOperator.PromotionIntentChecks
