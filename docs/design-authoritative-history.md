# Authoritative history tracking in the operator (one page)

Status: **design, implementation in progress (2026-10-09). No real-environment change.**
User direction: "the operator must track state so that this does not happen".

## Problem (from the code)

`masterHistoryRef` (Main.lean) lives in memory only, and `refreshMasterHistory`
overwrites it every 15 s with whatever node the map shows as Active master, as
long as its stats are complete. An ex-master that comes back under the same name
with an EMPTY DB and a new history can therefore replace the reference the
promotion decisions rely on. An operator restart erases the reference entirely.

## Two different things, kept apart

| | Authoritative history (per partition) | Observation (per copy) |
|---|---|---|
| What | the history the partition is ACCEPTED to be: `gen`, `master_id`, `epoch`, the holder `(node key, pod UID, boot id, copy id)`, `since`, `reason` (`first-build` / `adopted` / `promotion` / `bulk`) | what a copy reports: `(pod UID, boot id, copy id)`, `(master_id, epoch)`, applied position **within that history**, health flags, time |
| Changes only by | an explicit transition (below) | every successful probe |
| Persisted | yes, with an intent for the transition in progress | yes, when the binding, the history or the health changes (the position is rate-limited) |

A new observation **never** replaces the authoritative history. Positions are
compared only within the same `(master_id, epoch)`.

## Transitions (the ONLY ways the authoritative history changes)

1. **first-build**: the first master of a partition that has no record, AND the
   node map shows a first build (no map before, or the partition is new): its
   history is adopted once it is Active and readable. `gen = 1`.
2. **adopted** (upgrade from an operator without this record): a partition with
   a map but no record. It is adopted from the CURRENT master only if that
   master is Active, readable, NOT empty while another copy holds data, and the
   adoption is logged. Until then the record is **Unknown**: promotions on a
   history basis are held. A missing or corrupt record is never "first build".
3. **promotion**: before committing a map that promotes `K`, persist an INTENT
   `(partition, K, binding of K, fromGen, fromHistory, class, map version before)`.
   A failed intent write aborts the commit. After the commit, when `K` reports a
   new epoch WITH THE SAME BINDING, record `gen + 1` and clear the intent. If
   `K`'s binding changed first, the intent stays unresolved: CRITICAL, promotions
   of that partition are held.
4. **bulk** (flush_all / truncate on the master): the RECORDED holder, with the
   SAME binding, reports a new epoch: `gen + 1`, reason `bulk`. Any other node's
   new epoch (a restarted or empty ex-master: new boot id / copy id) is only an
   observation.
5. **restore**: NOT automatic. Needs an approval that does not exist yet (R8).

## Write order and recovery (the non-atomic window)

- Store: a ConfigMap `{cr}-history`, written with the resourceVersion read with it
  (optimistic concurrency: a second leader's stale write fails, it re-reads).
- Promotion: intent (persisted) -> map commit (persisted, then broadcast) ->
  observe K's new epoch -> record `gen + 1` + clear intent (persisted).
- On start or leader change: load the record. Missing ConfigMap with a present node
  map = Unknown (never first build). Unreadable/corrupt = Unknown. An intent present:
  if the persisted map version is past the intent's "before" and K is master
  there, the commit happened -> wait for K's epoch with the recorded binding;
  otherwise the commit never happened -> drop the intent (logged).
- Any write failure: the decision that needed it does not proceed (intent ->
  no commit; adoption -> intent kept, retried).

## The old master returning (re-registration race)

- It returns with a new boot id (and an empty DB gets a new copy id): it is not
  the recorded holder. Its history is an observation. It is a REJOINING copy:
  rebuild it from the authoritative history's holder; it is never a recovery
  source, a master candidate or read-eligible while its history differs.
- While the map still names it master (before detection), the operator treats the
  partition as having NO authoritative master when the master's binding is not
  the recorded holder's and its history differs: the existing empty-master
  early relief applies (a READ that showed it empty, never an unreadable one).
- No rebuild runs against a source whose observed history is not the
  authoritative one (no reverse rebuild from an empty copy onto the surviving copy).

## Not claimed

The operator's record is a decision basis, not distributed fencing: it does not
guarantee that no acknowledged write is lost (an asynchronous follower can be
behind; promotions of a lagging copy stay NOT LOSS-FREE). flared's own copy
protection and promotion refusal stay in place.

## Tests (paired)

- unit: every transition; each persistence write failing (intent, adoption,
  observation) leaves the decision not taken; Unknown / missing / corrupt record is
  never first build; a non-holder's new epoch never replaces the record.
- E2E: the empty-returning ex-master with a lagging healthy replica (promote the
  replica, every surviving key/value kept, new writes accepted, nothing rebuilt
  from the empty copy); the same with the operator RESTARTED and with a leader
  change between the intent and the adoption; the same shape with a partial copy
  (not promoted after the wait); an unreadable ex-master (not treated as empty).

---

## Review 2026-10-09 (061cd2b / cfd36f1): NOT production-ready — response plan

Six defects found by static review. The plan for each; implementation follows,
each fixed by a counterexample test (pure AND at Main's persistence /
distribution boundary with injected failures).

1. **Re-adoption of Unknown.** `adopt` adopted from the current master whatever
   the unknown reason, `replace` could overwrite a corrupt / foreign record, and an
   unreadable replica dropped out of `obs` (so `otherHasData` could be false and an
   empty master adopted). Plan: the unknown reason is a CODE — `absent`,
   `unreadable`, `corrupt`, `foreign`. A corrupt or foreign record is never
   overwritten or adopted automatically (CRITICAL; an operator deletes it and
   approves). An absent record with a node map is adopted only with an explicit
   MIGRATION APPROVAL (FlareCluster annotation
   `flare.gree.net/history-adoption-approved=<metadata.uid>`). To keep first builds
   automatic, the store is created (origin `first-build`) BEFORE the first node map
   is persisted, so a later "absent" can only be a migration or a loss. Adoption
   needs EVERY copy of the partition observed in that pass: an unobserved copy is
   never treated as empty.
2. **Stale source observations.** The rebuild gate used the persisted `obs` cache,
   ignored health, and treated a pending intent's target as allowed without any
   history check. Plan: at the commit boundary the source is read FRESH (pod UID,
   boot id, copy id, history, health, items) and must be the RECORD's holder
   binding with the record's history, healthy and not empty unless the record is
   empty. A pending intent permits nothing: rebuild assignments of that partition
   are held until it is resolved. On the real path (flared choosing the map
   master as its reconstruction source, and the switch), flared has no notion of
   the authoritative history; that check is NOT implemented there and is recorded
   as a residual (flared's own copy protection stays).
3. **Bulk could never be tracked.** `truncate` / `flush_all` bump the copy id
   (`uuid:N` → `uuid:N+1`) and advance the epoch with reason `bulk`, so "same
   binding" never held. Plan: the bulk transition requires the SAME pod UID and boot
   id, a copy id of the SAME uuid with generation exactly N+1, the reported epoch
   reason `bulk`, and a new epoch; the record then takes the new copy id. Anything
   else (another uuid, a new boot) stays an observation.
4. **tch and older flared.** Observations required master_id / epoch / copy id,
   and the rebuild gate and promotion intents applied to every backend, so a tch
   cluster or an rc56 / rc65 upgrade could hold forever. Plan: an explicit
   CAPABILITY per partition (`tracked` when every copy reports copy id, boot id,
   master_id and epoch; `untracked: <why>` otherwise — non-RocksDB backend or an
   older flared). Untracked partitions keep the previous behaviour (no intent, no
   history gate), logged once; the tch suites and the upgrade suite stay as they are.
5. **Intent recovery.** `beginIntent` overwrote a pending intent, commits did not
   refuse while one was pending, resolution accepted any later map version with
   the target as master and ignored health, and HELD was only a log line. Plan: an
   intent carries an id, the EXPECTED map version of its commit, fromGen /
   fromHist and the target binding; a new promotion in a partition with a pending
   intent is refused (until that intent is resolved or proven not committed);
   resolution requires the persisted map version to reach the expected one with the
   target master THERE, the target healthy with the same binding and a new
   history; HELD is persisted as the partition state (promotions and rebuilds of
   that partition refused, CRITICAL, RUNBOOK) — not only logged. The window where
   the target's binding changes between the commit and the adoption is fixed by an
   E2E that kills its flared in that window.
6. **Strict parser.** Duplicate part / intent / cluster lines, flags other than 0/1,
   unknown kind / reason, gen 0 and empty tokens were accepted. Plan: any of these
   makes the whole record CORRUPT (unknown, never adopted); no "last one wins".

Failure-injection tests at Main's boundary (E2E, CI only): a corrupt record, a
foreign record, an absent record with a node map (held until the migration
approval), an intent persisted and the operator restarted before the map commit
(the intent is proven not committed and dropped), the target's flared killed
between the commit and the adoption (HELD persisted, nothing promoted or rebuilt
in that partition), an unwritable record during bulk and during an intent.

## Implementation after the plan review (2026-10-09)

- **Hold beside the record.** `Part.known record hold`: a bulk seen part-way
  (copy id N+1 without its receipt), a crash between the copy-id bump and the
  receipt, or an intent whose target changed / is unhealthy / is not master in
  the committing map sets a HOLD next to the RETAINED record (never Unknown). The
  gates (promotion, rebuild, new intents) are closed while it stands; the same
  transition's receipt lifts it (bulk); an intent hold needs an operator
  (RUNBOOK #history-held).
- **Bulk receipt.** flared persists, in the DB and only after the new epoch is
  recorded, `pred succ epoch` per completed truncate / flush_all (the last 8),
  exported as `rocksdb_bulk_chain`. The operator follows the chain link by link
  from the recorded copy to the current one (two bulks between observations are
  followed, never assumed); same pod and boot, reason `bulk`, healthy.
- **Restart re-bind.** The holder restarted normally (same copy id, same
  history, healthy; new boot id or pod UID) is re-bound; the rebuild and
  promotion gates compare the COPY id and the history, not the process. An empty
  DB has a new copy id: never re-bound, rejoining.
- **Capability.** From complete replies only: modern / legacy / unreadable per
  node. Untracked only when every copy was observed and none is modern; an
  approved untracked partition becomes tracked once every copy is modern; a
  tracked partition is never downgraded; Unknown holds.
- **Intent proof.** Each promotion of an existing copy in a tracked partition
  persists an intent (id, expected map version, fromGen / fromHist, the
  target's binding read fresh) BEFORE the commit; the committed node map
  carries the id (`transition=` lines, the last 16). Resolution needs the
  PERSISTED map to carry the id; the persisted map reaching the expected version
  without it = that commit never happened (dropped). One pending intent per
  partition.
- **Lease.** Every history write re-checks the lease (holder = this pod, not
  expired); a corrupt / foreign / unreadable record is never written back.
- **First build vs migration.** The store is created (origin first-build) at
  the start of the first pass, before any node map is persisted. Afterwards an
  absent record with a node map needs the FlareCluster annotation
  `flare.gree.net/history-adoption-approved=<metadata.uid>`.

## Registration timeline (the existing path, verified in the code)

1. A master's process dies and comes back under the same name (a container
   restart: the pod-local DB is empty; a new copy id and a new epoch).
2. flared listens early but serves only after `startup_node` (`node add`) gave
   it the operator's map.
3. The operator's `NodeAdd` (Reconciler.lean) rejoins a key that already holds a
   partition slot as **Slave/Prepare** with `lastMasterOf` (it is not kept as
   master). Other nodes may still route to it as master until the next
   broadcast; its own map names no master for the partition, so it forwards
   and fails instead of answering from its empty copy (no write is acknowledged
   by it; a read is an error or a miss per readUnavailableError — R2).
4. The partition is masterless: a promotion-risk pass reads every non-master.
   **Previously** the refill could re-seat the `lastMasterOf` holder by data
   presence alone. **Now** the classifier (wired `rejoining`) marks a copy of
   another history than the authoritative record FORBIDDEN, the refill
   hard-excludes it, and the commit re-reads it fresh and aborts.
5. The replica of the recorded history (eligible, or lagging as the last
   resort) is promoted through an intent; the empty ex-master is rebuilt FROM it
   (the rebuild gate requires the record's holder as the source).

Still not covered (residual): flared itself does not know the authoritative
history when it picks a reconstruction source or switches copies; the window in
step 3 relies on the forwarded request failing.

## Verification map (status 2026-10-09 after CI 741d0c5; nothing here is reviewed)

Status words: **implemented** (code exists) / **local** (run on the author's
machine: Lean unit checks only) / **CI** (run in Linux CI) / **reviewed**.
An unexecuted test is never counted as evidence of a fix.

| Fix | Test | Boundary checked | Status |
|---|---|---|---|
| P1-1 the persisted map is the COMMITTED one; aborts stop it | E2E history-tracking (1): the persisted node map carries the transition id and names the replica master; the record adopts it | Main commit -> node-map ConfigMap -> history record | CI 741d0c5: (1) PASSED |
| P1-1 abort leaves the persisted map unchanged | E2E history-tracking (3b): with the record unwritable the promotion aborts and the persisted map does NOT name the replica master | Main commit -> node-map ConfigMap | CI 741d0c5: (3b) FAILED on its precondition (no Active P0 master) after (R) — unexplained |
| P1-2 restart with the new format | unit: committed map -> serializeNodeMap -> strict validate -> restored map -> resolveIntent; malformed transition rejected | pure (the same functions Main uses) | local |
| P1-2 / operator restart | E2E history-tracking (1) (operator restarted between the lag and the promotion) and (5) (operator restarted after the intent, before the map commit: the intent is dropped as uncommitted) | real restart, persisted map + record | CI 741d0c5: (1) PASSED; (5) FAILED on its precondition (no intent reached the barrier) — unexplained |
| first build: record write fails | E2E history-firstbuild: while writes are refused no history record, NO node map, the operator hands out no map (node sync empty), `node add` refused; after writes are allowed the record is created no later than the map, adopted as first build, writes acknowledged and replicated | Main ensureHistoryStore -> registration gate (TCP) -> node-map ConfigMap | CI 741d0c5: PASSED (test 16; group failed for other tests) |
| first build gate | unit mapMayBePersisted | pure | local |
| P1-3 legal empty master repairs / an empty other copy does not | unit P1-3 pair, CORRECTED after CI 741d0c5 (the recorded copy with the recorded history is allowed when empty whatever the record's reason — plain deletes included, empty-source 2; an empty other copy / other history refused); unit pair D (empty DB new copy: no re-bind, no bulk, rebuild refused); E2E history-tracking (R) (empty process under the master's name never seated; the replica's data kept; the ex-master rebuilt from it); the existing empty-source suites | pure + Main rebuild gate + refill | unit local (corrected); CI 741d0c5: (R) FAILED (cause not established, sampling fixed), empty-source 2 FAILED on the rule now corrected |
| same-copy restart recovers | unit pair C (re-bind, rebuild allowed); existing PVC suites (pvc-survival, copy-identity 11) restart with the same copy | pure + Main | unit local; E2E not run |
| partial / quarantine / unknown never promoted | unit (classifier, needs_rebuild (2), P1-4 seenOfReply health); E2E history-tracking (2) (part-way), promotion-reasons | pure + Main | unit local; CI 741d0c5: (2) PASSED |
| P1-4 capability | unit seenOfReply (legacy only without newer keys; partial / invalid / no UID unreadable; running / parked / partial unhealthy); after CI 741d0c5: a complete reply with R3 keys but NO copy key (non-RocksDB backend) = no copy evidence -> untracked, composed with establish + rebuildAllowed | pure (Main calls it) | local; the regression it fixes was found BY CI 741d0c5 (not yet re-run) |
| P1-5 intent fresh read | the code path (reclassifyAllows / commitTimeAllows + binding) — no dedicated E2E | Main commit | implemented; not run |
| P1-6 bulk receipt | C++ test_bulk_receipt_normal_failed_write_and_crash_before_epoch: return values (0 / -1 / -1) AND the state after reopen (receipt present, pending absent / finalised at reopen / no receipt, pending kept) for: normal, receipt write failing after the epoch, crash before the epoch | storage_rocksdb truncate + open | compiled in CI 741d0c5 (nix-linux success, 0 failures) but the totals equal b253fc0's, so its EXECUTION is not shown: the next run prints it by name |
| supplements | unit keepTransitions, begin / resolve record checks | pure | local |

### CI 741d0c5 (E2E 37834294217) — what it showed

- Regression (fixed, not yet re-run): non-RocksDB clusters read as unreadable ->
  no record -> every rebuild held ('not recorded'): breaker-migration, repair,
  topology, failover-data, authority failures were slave-assignment deadlocks.
- Regression (fixed, not yet re-run): empty-source 2 (master emptied by deletes)
  refused by the empty-source rule; 3-8 failed on its preconditions.
- Passed in CI on the real Main path: history-tracking (1) (empty ex-master,
  lagging replica promoted across an operator restart from the persisted
  history) and (2) (part-way copy forbidden, promoted once the marker is gone).
- Also PASSED in that run (CI, real Main path, NOT reviewed): (3a) failed
  history write not applied, (4) corrupt record never adopted / overwritten,
  (6) promotion target replaced before adoption -> HELD, and history-firstbuild
  16 (record write refused: no node map, no registration answered; after the
  permission returns, record no later than the map, writes replicated). The
  group as a whole failed, so these are single-test CI results; they are
  re-run with the fixes.
- restore-promotion harness defects: 35/36 sampling, wrong object for the
  committed version (both fixed); (R) cause not established (sampling fixed to
  real reads); (5) / (3b) precondition failures after (R) — unexplained.
