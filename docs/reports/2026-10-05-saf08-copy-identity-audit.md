# SAF-08 audit: how delete and promote decisions identify the surviving copy (2026-10-05)

Scope (user priority): audit how the copy a destructive or promoting
decision relies on is identified, and whether it is re-validated right
before acting. Structural refactoring (typed Pod observation records, pure
repair decisions) is deferred.

**Finding in one line.** Apart from the empty-master delete (UID
precondition), no decision binds its evidence to a pod UID or flared
process. The protection is indirect. A new flared process re-registers, bumps
the entry's `regEpoch`, and the commit merge lets that override a stale FSM
result. That covers a replacement only after it has registered. It does not
cover the window before registration, writes that bypass the merge, or the
pod deletes.

| # | Decision | Evidence keyed by | Re-validated before acting | Status |
|---|---|---|---|---|
| 1 | Empty-master self-heal delete (Main) | master: pod UID before/after stats; successor: node key | master UID precondition on the API delete; successor re-read from the live map | The UID precondition protects the DELETE TARGET only; it does not guarantee the surviving copy (review 2026-10-05). **Implemented, CI pending**: the successor's incarnation (UID and flared restart count) is bracketed around its fresh stats and must be stable to delete; the validated successor is pinned for the following drain while its pod stays that incarnation (else the pin is dropped and the commit-time check applies) |
| 2 | Stuck-Down restart delete | node key; stale `finalState` | no (delete by name) | **Open** (availability only on PVC) |
| 3 | Dead-node failover promotion | map Active + node key | merge only | NotReady candidates excluded (implemented). Ready is a snapshot, not identity (review 2026-10-05): a restart or replacement AFTER the observation is now caught at commit — every promoted node's incarnation (UID, flared restart count) must equal the one observed this pass, else the pass is dropped (implemented, CI pending) |
| 4 | Graceful drain promotion | map Active + node key | merge only | NotReady excluded; post-observation change caught at commit (implemented, CI pending) |
| 5 | Masterless refill, Active-slave tier | map Active + pod name | merge only | NotReady excluded; post-observation change caught at commit (implemented, CI pending) |
| 6 | Masterless refill, data-bearing tiers | `curr_items` by pod name | no | Partly: ex-masters probed while NotReady (2026-10-03). **Open**: evidence not bound to UID; if every probe fails, an empty `lastMasterOf` holder can be crowned |
| 7 | Zombie guard (FSM) | map Active + pod name | merge only | NotReady/unfit not promoted (implemented); post-observation change caught at commit (CI pending) |
| 8 | Zombie guard (TCP fast path) | map | none | Bootstrap only; low |
| 9 | Follow evidence | slave: node key + boot id vs the previous pass | boot change = Unknown for one pass | Open: the first reading after an operator restart is never marked; no re-read before commit |
| 10 | PREPARE-REPAIR activation | episode by node key; boot id informational | none | Implemented 2026-10-05, CI pending: the slave's boot id is re-read just before applying, and the apply requires an unchanged `regEpoch` (no seam test yet) |
| 11 | Replica-repair demotion (the copy is rebuilt) | ledger entry by dest; nothing about the source | target still a Slave | Implemented 2026-10-05, CI pending: the source's stats are bracketed by its incarnation; the atomic update requires the partition's master entry (key and regEpoch) to be the one checked; an EMPTY source is accepted only under the replica's own lineage AND (the same source epoch, a bulk epoch, or — review round 2026-10-05 — the replica's REBUILD EVIDENCE naming exactly the master's master_id and epoch), otherwise deferred (CI 37283759673: a replica caught up by WAL sync after a promotion is deferred; evidence implemented, CI pending) |
| 12 | Repair release / completion | node key + boot id at reseat | yes | Fine |
| 13 | Zone-repair swap | map | merge only | Open (assumes the remaining Active slave is real; the readiness rule does not reach it) |

## Review corrections (2026-10-05)

- Readiness proves state at the observation, not identity: excluding
  NotReady candidates closes the window before a replacement registers, not
  a restart or replacement AFTER the observation. The latter is now checked
  at commit (pod UID and flared restart count, observed vs now).
- The UID precondition on a delete protects the target; the surviving copy
  needs its own binding (row 1).
- An empty repair source is not always a loss: deleted-to-empty under the
  same lineage is a valid source.

## CI tests added (suite `copy-identity`, breaker-migration leg)

- **Same-name replacement.** The node is cordoned and slave A is
  force-deleted, so its same-name replacement stays Pending while the map
  says Active. The master is then drained. A must never be master, B must
  take over with every key, and the operator must log A as withheld.
  Without the readiness rule, the drain chose by map order alone.
- **Process restart.** A slave's flared is killed with -9 (same pod, new
  process) and the master is drained at once. That slave must not be
  promoted, and the other one takes over with every key. The window between
  the container restart and its re-registration is short, so this guards the
  outcome rather than isolating the rule.

- **Restart after observation** (promotion barrier seam
  `FLARE_TEST_PROMOTION_BARRIER`): the pass that chose a successor is held;
  that successor's flared is killed; on release the promotion must be
  ABORTED and a later pass promote a valid copy with every key.
- **Replacement after observation**: the same, with the chosen successor's
  pod replaced under the same name (node cordoned); the other slave takes
  over.
- ~~Legitimately emptied master~~ (CI 37283759673: deferred — that replica
  had caught up by WAL sync after a promotion, so its history could not be
  proven). Replaced by the `empty-source` suite below.

## Empty repair source: rebuild evidence (review round 2026-10-05)

A replica records which history it was rebuilt from — the source's
master_id and source epoch, bound to its own epoch at that moment — only
after a clean truncate + full dump whose source identity was the same at the
dump's start and end. The record lives in its own reserved key, not in the
source-epoch field (that field gates forwarded changes; the evidence must not
become a position). It is dropped before every rebuild, on every change of
the node's own history, and by a snapshot swap. The operator accepts an empty
master as a repair source when the evidence names exactly its master_id and
epoch.

Suite `empty-source` (truncate + full dump forced by test seams, dumps
throttled to ~50 s): evidence after a promotion; a legitimately emptied
master accepted; restart mid-dump leaves no evidence until a dump completes;
a source change mid-dump never leaves the old source's epoch; evidence naming
an earlier epoch than a promoted master's is refused (the replica keeps its
keys). Option B (a one-shot human approval bound to the copy and the source
history) is not implemented.

## Not done (follow-up)

- Rows 1, 2, 6, 9 and 13 as marked open.
- A barrier seam to hold PREPARE-REPAIR between its read and its apply,
  for a deterministic process-restart test of row 10.
- The typed Pod observation record, and moving repair decisions into pure
  functions (structural).
