/-
  StateMachine/RedundantCopy.lean — the operator's word that a parked
  replica's copy is redundant (docs/spec.md, "A redundant copy is discarded on
  the operator's word"; design: flare-ci-inputs/designs/
  REDUNDANT-COPY-DISCARD-2026-11-10.md).

  A copy that serves nothing is useless while its partition has a master and
  at least one OTHER Active slave of the master's current history on another
  Pod. `decide` is pure: Main gathers the `Facts` (stats, pods, the
  ledgers) and sends `rebuild_resume discard <uid> <copy id> <version>` only
  on `grant`; anything else is `keep` (a plain resume), with the reason.

  The map is not changed, so no existing proof changes.
-/
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.RedundantCopy

open FlareOperator.K8s

/-- Another copy of the partition, as Main read it. -/
structure Other where
  key : String
  /-- its pod's UID ("" = unknown) -/
  podUid : String
  /-- Active in the map and its pod Ready, not Terminating -/
  active : Bool
  /-- same `rocksdb_master_id` and `rocksdb_source_epoch` as the master
      (NodeMove.sameHistoryOf) -/
  sameHistory : Bool
  /-- a replica repair is open for it -/
  repairOpen : Bool
  /-- its own `rocksdb_copy_identity_consistent` / `rocksdb_quarantined`
      (none = not reported: fail closed) -/
  consistent : Option Nat
  quarantined : Option Nat
  /-- the master's `proxy_write_dropped[<it>]` / `proxy_write_failed[<it>]`,
      counted since the master's flared started (none = not reported: fail
      closed). Absolute, not an increase over a baseline: a baseline taken
      when the operator first looks (or after it restarts) would hide drops
      that happened before. -/
  dropped : Option Nat
  failed : Option Nat
  /-- not a continuous-replication follower, or proven current (the delete
      gate's survivor verdict); unknown = false -/
  followOk : Bool
  deriving Repr, BEq, Inhabited

/-- Everything `decide` reads about the node whose copy may be discarded. -/
structure Facts where
  key : String
  /-- the node's pod UID, the same before and after the stats read ("" = unknown or changed) -/
  podUid : String
  /-- `rocksdb_copy_id` ("" = unknown) -/
  copyId : String
  /-- flared's own `node_map_version` -/
  flaredMapVersion : Option Nat
  /-- `rocksdb_copy_identity_consistent` / `rocksdb_quarantined` -/
  consistent : Option Nat
  quarantined : Option Nat
  /-- the other copies of the partition -/
  others : List Other
  /-- nodes that may be promoted: a handover or node-move successor, a pinned
      successor, the copy a person chose to keep -/
  candidates : List String
  deriving Repr, Inhabited

inductive Verdict where
  | grant (podUid copyId : String) (version : Nat)
  | keep (why : String)
  deriving Repr, BEq

/-- A token flared accepts as a UID / copy id (it is one word on the wire). -/
def validToken (s : String) : Bool :=
  !s.isEmpty && s.all fun c => c.isAlphanum || c == ':' || c == '-' || c == '_' || c == '.'

/-- The Active master of partition `p`. -/
def masterOf (st : FlareClusterState) (p : Int) : Option String :=
  (st.nodeMap.find? fun (_, n) => n.role == FlareRole.Master && n.partition == p && n.state == FlareState.Active).map (·.1)

/-- The other copy's own evidence, all of it reported: identity consistent,
    not quarantined, and the master never dropped or failed a write to it
    since the master's flared started. Anything missing keeps the copy. -/
def evidenceOk (o : Other) : Bool :=
  o.consistent == some 1 && o.quarantined == some 0 && o.dropped == some 0 && o.failed == some 0

/-- `o` keeps the data of partition `p` while the key's copy is away: another
    node than the key and the master, a slave of `p` Active in the map, same
    history, no open repair, its evidence reported and clean (`evidenceOk`),
    a pod of its own, current if it follows. -/
def qualifies (st : FlareClusterState) (p : Int) (master : String) (f : Facts) (o : Other) : Bool :=
  o.key != f.key && o.key != master && o.active && o.sameHistory && !o.repairOpen && evidenceOk o
    && o.followOk && !o.podUid.isEmpty && o.podUid != f.podUid
    && (match st.lookupNode o.key with
        | some n => n.role == FlareRole.Slave && n.state == FlareState.Active && n.partition == p
        | none => false)

/-- May the node's copy be discarded? -/
def grantable (st : FlareClusterState) (f : Facts) : Bool :=
  match st.lookupNode f.key with
  | none => false
  | some n =>
    n.role == FlareRole.Slave && n.state == FlareState.Prepare && decide (n.partition ≥ 0)
    && (match masterOf st n.partition with
        | none => false
        | some mk => mk != f.key && f.others.any (qualifies st n.partition mk f))
    && !f.candidates.contains f.key
    && validToken f.podUid && validToken f.copyId
    && f.consistent == some 1 && f.quarantined == some 0
    && f.flaredMapVersion == some st.nodeMapVersion

/-- The first reason a copy is kept (for the log). -/
def why (st : FlareClusterState) (f : Facts) : String :=
  match st.lookupNode f.key with
  | none => "the node is not in the map"
  | some n =>
    if n.role == FlareRole.Master then "it is the partition's master"
    else if !(n.role == FlareRole.Slave && n.state == FlareState.Prepare) || n.partition < 0 then
      "it is not a rebuilding slave of a partition"
    else match masterOf st n.partition with
      | none => "the partition has no Active master (this copy may be the last data)"
      | some mk =>
        if f.candidates.contains f.key then "it is a promotion candidate"
        else if !validToken f.podUid then "its pod UID is unknown or changed during the read"
        else if !validToken f.copyId then "its copy id is unknown"
        else if f.consistent != some 1 then "its copy identity is not reported consistent"
        else if f.quarantined != some 0 then "its copy is quarantined or not reported"
        else if f.flaredMapVersion != some st.nodeMapVersion then "the node's map version differs from the operator's"
        else if !(f.others.any (qualifies st n.partition mk f)) then
          if f.others.any (fun o => o.key != f.key && o.key != mk && o.active && o.sameHistory && !evidenceOk o) then
            "the other Active slave's copy identity, quarantine state or the master's dropped/failed counters for it are not reported, or not zero"
          else "no other Active slave of the master's history on another pod holds the data"
        else "kept"

def decide (st : FlareClusterState) (f : Facts) : Verdict :=
  if grantable st f then .grant f.podUid f.copyId st.nodeMapVersion else .keep (why st f)

private theorem role_beq (a b : FlareRole) (h : (a == b) = true) : a = b := by
  revert h; cases a <;> cases b <;> decide

private theorem state_beq (a b : FlareState) (h : (a == b) = true) : a = b := by
  revert h; cases a <;> cases b <;> decide

/-- A grant means: the key's node is a slave of a partition with an Active
    master other than itself, and another slave, neither the key nor the
    master, Active in the map with the master's history, holds the data. -/
theorem grant_has_master_and_another_copy (st : FlareClusterState) (f : Facts) (u c : String) (v : Nat)
    (h : decide st f = .grant u c v) :
    ∃ n mk, st.lookupNode f.key = some n ∧ n.role = FlareRole.Slave ∧ masterOf st n.partition = some mk ∧ mk ≠ f.key
      ∧ ∃ o ∈ f.others, o.key ≠ f.key ∧ o.key ≠ mk ∧ o.sameHistory = true ∧ o.active = true
        ∧ ∃ m, st.lookupNode o.key = some m ∧ m.role = FlareRole.Slave ∧ m.state = FlareState.Active ∧ m.partition = n.partition := by
  have hg : grantable st f = true := by
    unfold decide at h
    split at h
    · assumption
    · cases h
  unfold grantable at hg
  cases hn : st.lookupNode f.key with
  | none => simp [hn] at hg
  | some n =>
    refine ⟨n, ?_⟩
    cases hm : masterOf st n.partition with
    | none => simp [hn, hm] at hg
    | some mk =>
      simp only [hn, hm, Bool.and_eq_true, beq_iff_eq, bne_iff_ne, ne_eq, decide_eq_true_eq, List.any_eq_true] at hg
      obtain ⟨⟨⟨⟨⟨⟨⟨⟨⟨hr, hs⟩, hp⟩, hmk, o, ho, hq⟩, _⟩, _⟩, _⟩, _⟩, _⟩, _⟩ := hg
      unfold qualifies at hq
      cases hlk : st.lookupNode o.key with
      | none => simp [hlk] at hq
      | some m =>
        simp only [hlk, Bool.and_eq_true, bne_iff_ne, ne_eq, beq_iff_eq, Bool.not_eq_true'] at hq
        obtain ⟨⟨⟨⟨⟨⟨⟨⟨⟨hk1, hk2⟩, hact⟩, hsame⟩, _⟩, _⟩, _⟩, _⟩, _⟩, ⟨⟨hmr, hms⟩, hmp⟩⟩ := hq
        exact ⟨mk, rfl, role_beq _ _ hr, rfl, hmk, o, ho, hk1, hk2, hsame, hact, m, hlk, role_beq _ _ hmr, state_beq _ _ hms, hmp⟩

/-- A grant never names the master or a promotion candidate. -/
theorem grant_is_not_master_or_candidate (st : FlareClusterState) (f : Facts) (u c : String) (v : Nat)
    (h : decide st f = .grant u c v) :
    f.candidates.contains f.key = false ∧ ∀ n, st.lookupNode f.key = some n → n.role ≠ FlareRole.Master := by
  have hg : grantable st f = true := by
    unfold decide at h
    split at h
    · assumption
    · cases h
  unfold grantable at hg
  cases hn : st.lookupNode f.key with
  | none => simp [hn] at hg
  | some n =>
    cases hm : masterOf st n.partition with
    | none => simp [hn, hm] at hg
    | some mk =>
      simp only [hn, hm, Bool.and_eq_true, beq_iff_eq, bne_iff_ne, ne_eq, decide_eq_true_eq, List.any_eq_true, Bool.not_eq_true'] at hg
      obtain ⟨⟨⟨⟨⟨⟨⟨⟨⟨hr, hs⟩, hp⟩, hmk, _⟩, hc⟩, _⟩, _⟩, _⟩, _⟩, _⟩ := hg
      refine ⟨by simpa using hc, ?_⟩
      intro n' hn' hmaster
      have hh : n' = n := (Option.some.inj hn').symm
      rw [hh, role_beq _ _ hr] at hmaster
      cases hmaster

/-- The grant carries the flared's own version and copy, as read. -/
theorem grant_carries_the_read_copy (st : FlareClusterState) (f : Facts) (u c : String) (v : Nat)
    (h : decide st f = .grant u c v) : u = f.podUid ∧ c = f.copyId ∧ v = st.nodeMapVersion := by
  unfold decide at h
  split at h
  · cases h; exact ⟨rfl, rfl, rfl⟩
  · cases h

end FlareOperator.RedundantCopy
