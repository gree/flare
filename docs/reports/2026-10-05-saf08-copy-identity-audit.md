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
| 1 | Empty-master self-heal delete (Main) | master: pod UID before/after stats; successor: node key | master UID precondition on the API delete; successor re-read from the live map | Delete safe. Open: the next pass's drain promotes `findActiveSuccessor`'s first entry, not necessarily the validated successor |
| 2 | Stuck-Down restart delete | node key; stale `finalState` | no (delete by name) | **Open** (availability only on PVC) |
| 3 | Dead-node failover promotion | map Active + node key | merge only | **Fixed 2026-10-05**: an Active slave whose pod is not Ready is not a candidate |
| 4 | Graceful drain promotion | map Active + node key | merge only | **Fixed** (same rule) |
| 5 | Masterless refill, Active-slave tier | map Active + pod name | merge only | **Fixed** (same rule) |
| 6 | Masterless refill, data-bearing tiers | `curr_items` by pod name | no | Partly: ex-masters probed while NotReady (2026-10-03). **Open**: evidence not bound to UID; if every probe fails, an empty `lastMasterOf` holder can be crowned |
| 7 | Zombie guard (FSM) | map Active + pod name | merge only | **Fixed** (same rule; unfit/NotReady not promoted, proxy left for the refill) |
| 8 | Zombie guard (TCP fast path) | map | none | Bootstrap only; low |
| 9 | Follow evidence | slave: node key + boot id vs the previous pass | boot change = Unknown for one pass | Open: the first reading after an operator restart is never marked; no re-read before commit |
| 10 | PREPARE-REPAIR activation | episode by node key; boot id informational | none | **Fixed 2026-10-05**: the slave's boot id is re-read just before applying, and the apply requires an unchanged `regEpoch` |
| 11 | Replica-repair demotion (the copy is rebuilt) | ledger entry by dest; nothing about the source | target still a Slave | **Fixed 2026-10-05**: deferred unless the partition's CURRENT master is known to hold data; the demotion is an atomic re-check (`regEpoch`) |
| 12 | Repair release / completion | node key + boot id at reseat | yes | Fine |
| 13 | Zone-repair swap | map | merge only | Open (assumes the remaining Active slave is real; the readiness rule does not reach it) |

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

## Not done (follow-up)

- Rows 1, 2, 6, 9 and 13 as marked open.
- A barrier seam to hold PREPARE-REPAIR between its read and its apply,
  for a deterministic process-restart test of row 10.
- The typed Pod observation record, and moving repair decisions into pure
  functions (structural).
