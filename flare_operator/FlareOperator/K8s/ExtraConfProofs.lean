/-
  ExtraConfProofs.lean - the CR's `spec.rocksdb` reaches flared's `extra.conf` exactly.

  For every field of `RocksdbConfigSpec`: `some v` gives exactly one line
  `key = render v` (0 and both Bools included), `none` gives no line for the
  key. The keys are listed once (`RocksdbConfigSpec.entries`), none is a prefix
  of another, `hasAny = false ↔ toExtraConf = ""`, and `renderFlaredExtraConf`
  keeps the rocksdb lines whole and apart from the cluster-replication block.
  Nothing is assumed: the file has no proof holes and no added axioms.
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.K8s.Bridge

namespace FlareOperator.K8s.ExtraConfProofs

open FlareOperator.K8s
open FlareOperator.K8s.Bridge

/-! ## Keys: ordered, distinct, none a prefix of another -/

/-- Neither key is a prefix of the other (so `key = v` cannot be read as another key). -/
def PrefixFree (a b : String) : Prop :=
  ¬ a.toList <+: b.toList ∧ ¬ b.toList <+: a.toList

theorem prefixFree_symm {a b : String} (h : PrefixFree a b) : PrefixFree b a := ⟨h.2, h.1⟩

/-- The keys, in line order, are pairwise prefix-free (hence distinct). -/
theorem keys_prefixFree : RocksdbConfigSpec.keys.Pairwise PrefixFree := by
  unfold PrefixFree RocksdbConfigSpec.keys RocksdbConfigSpec.entries
  decide

theorem keys_length : RocksdbConfigSpec.keys.length = 21 := by
  simp [RocksdbConfigSpec.keys, RocksdbConfigSpec.entries]

/-- The line order is fixed by the key list, whatever the values are. -/
theorem entries_keys (r : RocksdbConfigSpec) : r.entries.map Prod.fst = RocksdbConfigSpec.keys := by
  simp [RocksdbConfigSpec.keys, RocksdbConfigSpec.entries]

theorem entries_pairwise (r : RocksdbConfigSpec) :
    r.entries.Pairwise (fun a b => PrefixFree a.1 b.1) := by
  have := keys_prefixFree
  rw [← entries_keys r] at this
  exact List.pairwise_map.mp this

/-- No key of the rocksdb block can be mistaken for a cluster-replication key. -/
theorem keys_not_cluster_replication :
    ∀ k ∈ RocksdbConfigSpec.keys, ¬ ("cluster-replication".toList <+: k.toList) := by
  unfold RocksdbConfigSpec.keys RocksdbConfigSpec.entries
  decide

/-! ## Lines -/

theorem line_prefix {k₁ k₂ s₁ s₂ : String} (h : k₁ ++ " = " ++ s₁ = k₂ ++ " = " ++ s₂) :
    k₁.toList <+: k₂.toList ∨ k₂.toList <+: k₁.toList := by
  have h' := congrArg String.data h
  simp only [String.data_append, List.append_assoc] at h'
  exact List.prefix_or_prefix_of_prefix ⟨_, rfl⟩ ⟨_, h'.symm⟩

def lineOf (e : String × Option String) : Option String :=
  e.2.map fun s => e.1 ++ " = " ++ s

theorem lines_eq (r : RocksdbConfigSpec) : r.lines = r.entries.filterMap lineOf := rfl

theorem pairwise_forall {α : Type} {R : α → α → Prop} (hs : ∀ a b, R a b → R b a) :
    ∀ (E : List α), E.Pairwise R → ∀ a ∈ E, ∀ b ∈ E, a ≠ b → R a b
  | [], _, a, ha, _, _, _ => by simp at ha
  | x :: E, h, a, ha, b, hb, hne => by
    have hp := List.pairwise_cons.mp h
    rcases List.mem_cons.mp ha with rfl | ha' <;> rcases List.mem_cons.mp hb with rfl | hb'
    · exact absurd rfl hne
    · exact hp.1 _ hb'
    · exact hs _ _ (hp.1 _ ha')
    · exact pairwise_forall hs E hp.2 _ ha' _ hb' hne

/-- Two entries of a prefix-free list that render the same line are the same entry. -/
theorem entry_of_line {E : List (String × Option String)}
    (hE : E.Pairwise (fun a b => PrefixFree a.1 b.1))
    {k k' : String} {o : Option String} {s s' : String}
    (he : (k, o) ∈ E) (he' : (k', some s') ∈ E)
    (hl : k' ++ " = " ++ s' = k ++ " = " ++ s) : (k', some s') = (k, o) := by
  by_cases hne : (k', some s') = (k, o)
  · exact hne
  · have := pairwise_forall (fun _ _ h => prefixFree_symm h) E hE _ he' _ he hne
    rcases line_prefix hl with h | h
    · exact absurd h this.1
    · exact absurd h this.2

theorem nodup_lines {E : List (String × Option String)}
    (hE : E.Pairwise (fun a b => PrefixFree a.1 b.1)) : (E.filterMap lineOf).Nodup := by
  induction E with
  | nil => simp
  | cons e E ih =>
    obtain ⟨k, o⟩ := e
    have hp := List.pairwise_cons.mp hE
    have ih' := ih hp.2
    cases o with
    | none => simpa [lineOf] using ih'
    | some s =>
      show ((k ++ " = " ++ s) :: E.filterMap lineOf).Nodup
      refine List.nodup_cons.mpr ⟨?_, ih'⟩
      intro hm
      obtain ⟨⟨k', o'⟩, hmem, hmap⟩ := List.mem_filterMap.mp hm
      cases o' with
      | none => simp [lineOf] at hmap
      | some s' =>
        simp only [lineOf, Option.map_some, Option.some.injEq] at hmap
        have := hp.1 _ hmem
        rcases line_prefix hmap with h | h
        · exact this.2 h
        · exact this.1 h

theorem count_of_nodup {α : Type} [BEq α] [LawfulBEq α] {a : α} :
    ∀ {l : List α}, l.Nodup → a ∈ l → l.count a = 1
  | [], _, h => by simp at h
  | x :: t, hn, h => by
    have hn' := List.nodup_cons.mp hn
    by_cases hx : x = a
    · subst hx
      simp [List.count_cons, List.count_eq_zero.mpr hn'.1]
    · have : a ∈ t := by
        rcases List.mem_cons.mp h with h | h
        · exact absurd h.symm hx
        · exact h
      have := count_of_nodup hn'.2 this
      simp [List.count_cons, this, hx]

theorem count_some (r : RocksdbConfigSpec) (k s : String) (h : (k, some s) ∈ r.entries) :
    r.lines.count (k ++ " = " ++ s) = 1 := by
  rw [lines_eq]
  apply count_of_nodup (nodup_lines (entries_pairwise r))
  exact List.mem_filterMap.mpr ⟨_, h, by simp [lineOf]⟩

theorem not_mem_none (r : RocksdbConfigSpec) (k : String) (h : (k, none) ∈ r.entries) :
    ∀ s, (k ++ " = " ++ s) ∉ r.lines := by
  intro s hm
  rw [lines_eq] at hm
  obtain ⟨⟨k', o'⟩, hmem, hmap⟩ := List.mem_filterMap.mp hm
  cases o' with
  | none => simp [lineOf] at hmap
  | some s' =>
    simp only [lineOf, Option.map_some, Option.some.injEq] at hmap
    have := entry_of_line (entries_pairwise r) h hmem hmap
    simp at this

/-! ## Per field -/

theorem blockCacheSizeMb_some (r : RocksdbConfigSpec) (v : Nat) (h : r.blockCacheSizeMb = some v) :
    r.lines.count ("rocksdb-block-cache-size-mb = " ++ toString v) = 1 :=
  count_some r "rocksdb-block-cache-size-mb" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem blockCacheSizeMb_none (r : RocksdbConfigSpec) (h : r.blockCacheSizeMb = none) :
    ∀ s, ("rocksdb-block-cache-size-mb = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-block-cache-size-mb" (by simp [RocksdbConfigSpec.entries, h])

theorem writeBufferSizeMb_some (r : RocksdbConfigSpec) (v : Nat) (h : r.writeBufferSizeMb = some v) :
    r.lines.count ("rocksdb-write-buffer-size-mb = " ++ toString v) = 1 :=
  count_some r "rocksdb-write-buffer-size-mb" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem writeBufferSizeMb_none (r : RocksdbConfigSpec) (h : r.writeBufferSizeMb = none) :
    ∀ s, ("rocksdb-write-buffer-size-mb = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-write-buffer-size-mb" (by simp [RocksdbConfigSpec.entries, h])

theorem maxWriteBufferNumber_some (r : RocksdbConfigSpec) (v : Nat) (h : r.maxWriteBufferNumber = some v) :
    r.lines.count ("rocksdb-max-write-buffer-number = " ++ toString v) = 1 :=
  count_some r "rocksdb-max-write-buffer-number" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem maxWriteBufferNumber_none (r : RocksdbConfigSpec) (h : r.maxWriteBufferNumber = none) :
    ∀ s, ("rocksdb-max-write-buffer-number = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-max-write-buffer-number" (by simp [RocksdbConfigSpec.entries, h])

theorem walTtlSeconds_some (r : RocksdbConfigSpec) (v : Nat) (h : r.walTtlSeconds = some v) :
    r.lines.count ("rocksdb-wal-ttl-seconds = " ++ toString v) = 1 :=
  count_some r "rocksdb-wal-ttl-seconds" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem walTtlSeconds_none (r : RocksdbConfigSpec) (h : r.walTtlSeconds = none) :
    ∀ s, ("rocksdb-wal-ttl-seconds = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-wal-ttl-seconds" (by simp [RocksdbConfigSpec.entries, h])

theorem walSizeLimitMb_some (r : RocksdbConfigSpec) (v : Nat) (h : r.walSizeLimitMb = some v) :
    r.lines.count ("rocksdb-wal-size-limit-mb = " ++ toString v) = 1 :=
  count_some r "rocksdb-wal-size-limit-mb" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem walSizeLimitMb_none (r : RocksdbConfigSpec) (h : r.walSizeLimitMb = none) :
    ∀ s, ("rocksdb-wal-size-limit-mb = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-wal-size-limit-mb" (by simp [RocksdbConfigSpec.entries, h])

theorem syncWrites_some (r : RocksdbConfigSpec) (b : Bool) (h : r.syncWrites = some b) :
    r.lines.count ("rocksdb-sync-writes = " ++ (if b then "true" else "false")) = 1 :=
  count_some r "rocksdb-sync-writes" (if b then "true" else "false") (by simp [RocksdbConfigSpec.entries, h])

theorem syncWrites_true (r : RocksdbConfigSpec) (h : r.syncWrites = some true) :
    r.lines.count "rocksdb-sync-writes = true" = 1 := by
  simpa using syncWrites_some r true h

theorem syncWrites_false (r : RocksdbConfigSpec) (h : r.syncWrites = some false) :
    r.lines.count "rocksdb-sync-writes = false" = 1 := by
  simpa using syncWrites_some r false h

theorem syncWrites_none (r : RocksdbConfigSpec) (h : r.syncWrites = none) :
    ∀ s, ("rocksdb-sync-writes = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-sync-writes" (by simp [RocksdbConfigSpec.entries, h])

theorem resyncFailureThreshold_some (r : RocksdbConfigSpec) (v : Nat) (h : r.resyncFailureThreshold = some v) :
    r.lines.count ("rocksdb-resync-failure-threshold = " ++ toString v) = 1 :=
  count_some r "rocksdb-resync-failure-threshold" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem resyncFailureThreshold_none (r : RocksdbConfigSpec) (h : r.resyncFailureThreshold = none) :
    ∀ s, ("rocksdb-resync-failure-threshold = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-resync-failure-threshold" (by simp [RocksdbConfigSpec.entries, h])

theorem walMaxBatchBytes_some (r : RocksdbConfigSpec) (v : Nat) (h : r.walMaxBatchBytes = some v) :
    r.lines.count ("rocksdb-wal-max-batch-bytes = " ++ toString v) = 1 :=
  count_some r "rocksdb-wal-max-batch-bytes" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem walMaxBatchBytes_none (r : RocksdbConfigSpec) (h : r.walMaxBatchBytes = none) :
    ∀ s, ("rocksdb-wal-max-batch-bytes = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-wal-max-batch-bytes" (by simp [RocksdbConfigSpec.entries, h])

theorem walSyncBwlimit_some (r : RocksdbConfigSpec) (v : Nat) (h : r.walSyncBwlimit = some v) :
    r.lines.count ("rocksdb-wal-sync-bwlimit = " ++ toString v) = 1 :=
  count_some r "rocksdb-wal-sync-bwlimit" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem walSyncBwlimit_none (r : RocksdbConfigSpec) (h : r.walSyncBwlimit = none) :
    ∀ s, ("rocksdb-wal-sync-bwlimit = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-wal-sync-bwlimit" (by simp [RocksdbConfigSpec.entries, h])

theorem walSyncInterval_some (r : RocksdbConfigSpec) (v : Nat) (h : r.walSyncInterval = some v) :
    r.lines.count ("rocksdb-wal-sync-interval = " ++ toString v) = 1 :=
  count_some r "rocksdb-wal-sync-interval" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem walSyncInterval_none (r : RocksdbConfigSpec) (h : r.walSyncInterval = none) :
    ∀ s, ("rocksdb-wal-sync-interval = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-wal-sync-interval" (by simp [RocksdbConfigSpec.entries, h])

theorem snapshotBwlimit_some (r : RocksdbConfigSpec) (v : Nat) (h : r.snapshotBwlimit = some v) :
    r.lines.count ("rocksdb-snapshot-bwlimit = " ++ toString v) = 1 :=
  count_some r "rocksdb-snapshot-bwlimit" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem snapshotBwlimit_none (r : RocksdbConfigSpec) (h : r.snapshotBwlimit = none) :
    ∀ s, ("rocksdb-snapshot-bwlimit = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-snapshot-bwlimit" (by simp [RocksdbConfigSpec.entries, h])

theorem flushAllEnabled_some (r : RocksdbConfigSpec) (b : Bool) (h : r.flushAllEnabled = some b) :
    r.lines.count ("flush-all-enabled = " ++ (if b then "true" else "false")) = 1 :=
  count_some r "flush-all-enabled" (if b then "true" else "false") (by simp [RocksdbConfigSpec.entries, h])

theorem flushAllEnabled_true (r : RocksdbConfigSpec) (h : r.flushAllEnabled = some true) :
    r.lines.count "flush-all-enabled = true" = 1 := by
  simpa using flushAllEnabled_some r true h

theorem flushAllEnabled_false (r : RocksdbConfigSpec) (h : r.flushAllEnabled = some false) :
    r.lines.count "flush-all-enabled = false" = 1 := by
  simpa using flushAllEnabled_some r false h

theorem flushAllEnabled_none (r : RocksdbConfigSpec) (h : r.flushAllEnabled = none) :
    ∀ s, ("flush-all-enabled = " ++ s) ∉ r.lines :=
  not_mem_none r "flush-all-enabled" (by simp [RocksdbConfigSpec.entries, h])

theorem backupKeep_some (r : RocksdbConfigSpec) (v : Nat) (h : r.backupKeep = some v) :
    r.lines.count ("rocksdb-backup-keep = " ++ toString v) = 1 :=
  count_some r "rocksdb-backup-keep" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem backupKeep_none (r : RocksdbConfigSpec) (h : r.backupKeep = none) :
    ∀ s, ("rocksdb-backup-keep = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-backup-keep" (by simp [RocksdbConfigSpec.entries, h])

theorem rebuildReserveBytes_some (r : RocksdbConfigSpec) (v : Nat) (h : r.rebuildReserveBytes = some v) :
    r.lines.count ("rocksdb-rebuild-reserve-bytes = " ++ toString v) = 1 :=
  count_some r "rocksdb-rebuild-reserve-bytes" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem rebuildReserveBytes_none (r : RocksdbConfigSpec) (h : r.rebuildReserveBytes = none) :
    ∀ s, ("rocksdb-rebuild-reserve-bytes = " ++ s) ∉ r.lines :=
  not_mem_none r "rocksdb-rebuild-reserve-bytes" (by simp [RocksdbConfigSpec.entries, h])

theorem readUnavailableError_some (r : RocksdbConfigSpec) (b : Bool) (h : r.readUnavailableError = some b) :
    r.lines.count ("read-unavailable-error = " ++ (if b then "true" else "false")) = 1 :=
  count_some r "read-unavailable-error" (if b then "true" else "false") (by simp [RocksdbConfigSpec.entries, h])

theorem readUnavailableError_true (r : RocksdbConfigSpec) (h : r.readUnavailableError = some true) :
    r.lines.count "read-unavailable-error = true" = 1 := by
  simpa using readUnavailableError_some r true h

theorem readUnavailableError_false (r : RocksdbConfigSpec) (h : r.readUnavailableError = some false) :
    r.lines.count "read-unavailable-error = false" = 1 := by
  simpa using readUnavailableError_some r false h

theorem readUnavailableError_none (r : RocksdbConfigSpec) (h : r.readUnavailableError = none) :
    ∀ s, ("read-unavailable-error = " ++ s) ∉ r.lines :=
  not_mem_none r "read-unavailable-error" (by simp [RocksdbConfigSpec.entries, h])

theorem replIdentityForward_some (r : RocksdbConfigSpec) (b : Bool) (h : r.replIdentityForward = some b) :
    r.lines.count ("repl-identity-forward = " ++ (if b then "true" else "false")) = 1 :=
  count_some r "repl-identity-forward" (if b then "true" else "false") (by simp [RocksdbConfigSpec.entries, h])

theorem replIdentityForward_true (r : RocksdbConfigSpec) (h : r.replIdentityForward = some true) :
    r.lines.count "repl-identity-forward = true" = 1 := by
  simpa using replIdentityForward_some r true h

theorem replIdentityForward_false (r : RocksdbConfigSpec) (h : r.replIdentityForward = some false) :
    r.lines.count "repl-identity-forward = false" = 1 := by
  simpa using replIdentityForward_some r false h

theorem replIdentityForward_none (r : RocksdbConfigSpec) (h : r.replIdentityForward = none) :
    ∀ s, ("repl-identity-forward = " ++ s) ∉ r.lines :=
  not_mem_none r "repl-identity-forward" (by simp [RocksdbConfigSpec.entries, h])

theorem replFollowEnabled_some (r : RocksdbConfigSpec) (b : Bool) (h : r.replFollowEnabled = some b) :
    r.lines.count ("repl-follow-enabled = " ++ (if b then "true" else "false")) = 1 :=
  count_some r "repl-follow-enabled" (if b then "true" else "false") (by simp [RocksdbConfigSpec.entries, h])

theorem replFollowEnabled_true (r : RocksdbConfigSpec) (h : r.replFollowEnabled = some true) :
    r.lines.count "repl-follow-enabled = true" = 1 := by
  simpa using replFollowEnabled_some r true h

theorem replFollowEnabled_false (r : RocksdbConfigSpec) (h : r.replFollowEnabled = some false) :
    r.lines.count "repl-follow-enabled = false" = 1 := by
  simpa using replFollowEnabled_some r false h

theorem replFollowEnabled_none (r : RocksdbConfigSpec) (h : r.replFollowEnabled = none) :
    ∀ s, ("repl-follow-enabled = " ++ s) ∉ r.lines :=
  not_mem_none r "repl-follow-enabled" (by simp [RocksdbConfigSpec.entries, h])

theorem replFollowPollIntervalUsec_some (r : RocksdbConfigSpec) (v : Nat) (h : r.replFollowPollIntervalUsec = some v) :
    r.lines.count ("repl-follow-poll-interval-usec = " ++ toString v) = 1 :=
  count_some r "repl-follow-poll-interval-usec" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem replFollowPollIntervalUsec_none (r : RocksdbConfigSpec) (h : r.replFollowPollIntervalUsec = none) :
    ∀ s, ("repl-follow-poll-interval-usec = " ++ s) ∉ r.lines :=
  not_mem_none r "repl-follow-poll-interval-usec" (by simp [RocksdbConfigSpec.entries, h])

theorem maxTotalThreadQueue_some (r : RocksdbConfigSpec) (v : Nat) (h : r.maxTotalThreadQueue = some v) :
    r.lines.count ("max-total-thread-queue = " ++ toString v) = 1 :=
  count_some r "max-total-thread-queue" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem maxTotalThreadQueue_none (r : RocksdbConfigSpec) (h : r.maxTotalThreadQueue = none) :
    ∀ s, ("max-total-thread-queue = " ++ s) ∉ r.lines :=
  not_mem_none r "max-total-thread-queue" (by simp [RocksdbConfigSpec.entries, h])

theorem noreplyWindowLimit_some (r : RocksdbConfigSpec) (v : Nat) (h : r.noreplyWindowLimit = some v) :
    r.lines.count ("noreply-window-limit = " ++ toString v) = 1 :=
  count_some r "noreply-window-limit" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem noreplyWindowLimit_none (r : RocksdbConfigSpec) (h : r.noreplyWindowLimit = none) :
    ∀ s, ("noreply-window-limit = " ++ s) ∉ r.lines :=
  not_mem_none r "noreply-window-limit" (by simp [RocksdbConfigSpec.entries, h])

theorem clientIdleTimeoutSeconds_some (r : RocksdbConfigSpec) (v : Nat) (h : r.clientIdleTimeoutSeconds = some v) :
    r.lines.count ("client-idle-timeout = " ++ toString v) = 1 :=
  count_some r "client-idle-timeout" (toString v) (by simp [RocksdbConfigSpec.entries, h])

theorem clientIdleTimeoutSeconds_none (r : RocksdbConfigSpec) (h : r.clientIdleTimeoutSeconds = none) :
    ∀ s, ("client-idle-timeout = " ++ s) ∉ r.lines :=
  not_mem_none r "client-idle-timeout" (by simp [RocksdbConfigSpec.entries, h])

/-- A zero is rendered like any other value. -/
theorem zero_is_rendered (r : RocksdbConfigSpec) (h : r.walTtlSeconds = some 0) :
    r.lines.count "rocksdb-wal-ttl-seconds = 0" = 1 := walTtlSeconds_some r 0 h

/-! ## `hasAny` and the empty string -/

theorem hasAny_false_iff_lines_nil (r : RocksdbConfigSpec) :
    r.hasAny = false ↔ r.lines = [] := by
  simp [RocksdbConfigSpec.hasAny, RocksdbConfigSpec.lines, RocksdbConfigSpec.entries,
    List.filterMap_eq_nil_iff, Bool.or_eq_false_iff, and_assoc, and_left_comm]

theorem line_ne_empty {l : String} (r : RocksdbConfigSpec) (h : l ∈ r.lines) : l ≠ "" := by
  rw [lines_eq] at h
  obtain ⟨⟨k, o⟩, _, hmap⟩ := List.mem_filterMap.mp h
  cases o with
  | none => simp [lineOf] at hmap
  | some s =>
    simp only [lineOf, Option.map_some, Option.some.injEq] at hmap
    intro he
    have := congrArg String.length (hmap.trans he)
    simp [String.length_append] at this
    have h3 : " = ".length = 3 := by decide
    omega

theorem go_append (s : String) : ∀ (t : List String) (acc : String),
    String.intercalate.go acc s t = acc ++ String.intercalate.go "" s t
  | [], acc => by simp [String.intercalate.go]
  | b :: t, acc => by
    simp only [String.intercalate.go]
    rw [go_append s t (acc ++ s ++ b), go_append s t ("" ++ s ++ b)]
    simp [String.append_assoc]

theorem intercalate_cons_cons (s a b : String) (t : List String) :
    String.intercalate s (a :: b :: t) = a ++ s ++ String.intercalate s (b :: t) := by
  show String.intercalate.go a s (b :: t) = _
  rw [String.intercalate.go, go_append s t (a ++ s ++ b)]
  show _ = a ++ s ++ String.intercalate.go b s t
  rw [go_append s t b]
  simp [String.append_assoc]

theorem intercalate_ne_empty (l : String) (ls : List String) (hl : l ≠ "") :
    String.intercalate "\n" (l :: ls) ≠ "" := by
  intro h
  apply hl
  cases ls with
  | nil => simpa [String.intercalate, String.intercalate.go] using h
  | cons b t =>
    rw [intercalate_cons_cons] at h
    have := congrArg String.data h
    simp only [String.data_append, List.append_eq_nil_iff] at this
    exact String.ext this.1.1

/-- `hasAny r = false ↔ toExtraConf r = ""`. -/
theorem hasAny_false_iff (r : RocksdbConfigSpec) :
    r.hasAny = false ↔ r.toExtraConf = "" := by
  rw [hasAny_false_iff_lines_nil]
  constructor
  · intro h
    simp [RocksdbConfigSpec.toExtraConf, h, String.intercalate]
  · intro h
    cases hl : r.lines with
    | nil => rfl
    | cons l ls =>
      exfalso
      apply intercalate_ne_empty l ls (line_ne_empty r (by simp [hl]))
      simpa [RocksdbConfigSpec.toExtraConf, hl] using h

/-! ## `renderFlaredExtraConf` -/

/-- `l` is a whole line of `s`: it starts the text or follows a `\n`, and it ends the text or
    precedes a `\n`. -/
def IsLineOf (l s : String) : Prop :=
  ∃ pre post, s = pre ++ l ++ post ∧ (pre = "" ∨ ∃ p, pre = p ++ "\n") ∧
    (post = "" ∨ ∃ q, post = "\n" ++ q)

theorem isLineOf_intercalate {l : String} :
    ∀ {ls : List String}, l ∈ ls → IsLineOf l (String.intercalate "\n" ls)
  | [], h => by simp at h
  | [x], h => by
    have : l = x := by simpa using h
    subst this
    exact ⟨"", "", by simp [String.intercalate, String.intercalate.go], Or.inl rfl, Or.inl rfl⟩
  | x :: y :: t, h => by
    rw [intercalate_cons_cons]
    rcases List.mem_cons.mp h with rfl | h'
    · exact ⟨"", "\n" ++ String.intercalate "\n" (y :: t),
        by simp [String.append_assoc], Or.inl rfl, Or.inr ⟨_, rfl⟩⟩
    · obtain ⟨pre, post, he, hpre, hpost⟩ := isLineOf_intercalate h'
      refine ⟨x ++ "\n" ++ pre, post, by rw [he]; simp [String.append_assoc], Or.inr ?_, hpost⟩
      rcases hpre with rfl | ⟨p, rfl⟩
      · exact ⟨x, by simp⟩
      · exact ⟨x ++ "\n" ++ p, by simp [String.append_assoc]⟩

/-- Every rocksdb line is a whole line of the rendered block. -/
theorem lines_isLineOf (r : RocksdbConfigSpec) {l : String} (h : l ∈ r.lines) :
    IsLineOf l r.toExtraConf :=
  isLineOf_intercalate h

/-- The rendered file is the rocksdb block, a blank line, and the replication block
    (just the replication block when there is no rocksdb line). -/
theorem render_eq (r : RocksdbConfigSpec) (repl : Option ClusterReplicationSpec) (off : Bool) :
    renderFlaredExtraConf r repl off =
      (if r.hasAny then r.toExtraConf ++ "\n\n" else "") ++ renderReplicationBlock repl off := by
  unfold renderFlaredExtraConf
  by_cases h : r.hasAny = true
  · have hne : r.toExtraConf ≠ "" := fun he =>
      absurd ((hasAny_false_iff r).mpr he) (by simp [h])
    simp [h, hne]
  · have h' : r.hasAny = false := by simpa using h
    have he := (hasAny_false_iff r).mp h'
    simp [h', he]

/-- Each rocksdb line is a whole line of the file `renderFlaredExtraConf` writes. -/
theorem render_contains_rocksdb_lines (r : RocksdbConfigSpec) (repl : Option ClusterReplicationSpec)
    (off : Bool) {l : String} (h : l ∈ r.lines) : IsLineOf l (renderFlaredExtraConf r repl off) := by
  have hany : r.hasAny = true := by
    cases hh : r.hasAny
    · have := (hasAny_false_iff_lines_nil r).mp hh
      simp [this] at h
    · rfl
  obtain ⟨pre, post, he, hpre, hpost⟩ := lines_isLineOf r h
  rw [render_eq, hany, he]
  refine ⟨pre, post ++ "\n\n" ++ renderReplicationBlock repl off, by simp [String.append_assoc], hpre, Or.inr ?_⟩
  rcases hpost with rfl | ⟨q, rfl⟩
  · exact ⟨"\n" ++ renderReplicationBlock repl off, by
      rw [← String.append_assoc]; rfl⟩
  · exact ⟨q ++ "\n\n" ++ renderReplicationBlock repl off, by simp [String.append_assoc]⟩

end FlareOperator.K8s.ExtraConfProofs
