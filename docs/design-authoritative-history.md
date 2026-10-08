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
