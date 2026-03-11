# Flare Operator — Current Status & Plan

## Summary

Implementing native TCP topology broadcast in the operator to fix the root cause of
inconsistent node views across flared pods (P0=100, P1=0 bug).

---

## What Has Been Done (Committed: `1723643`)

1. **TcpServer.lean** — Race condition fix: replaced non-atomic get/set with `modifyGet`
2. **Kubectl.lean** — Replaced fragile manual JSON parsing with `Lean.Data.Json`
3. **E2E Tests** — Replaced `IO.sleep` with `waitForCondition` in all test suites
4. **ScaleInSlave.lean** — Reverted per-partition-master write to single-entry proxy routing

## What Has Been Done (Uncommitted — Working Tree)

### TcpServer.lean — Native TCP Topology Broadcast

Added the original flarei broadcast mechanism directly in the TCP server:

- **`ServerState`** now tracks `activeSockets : IO.Ref (List (Nat × Socket))` and
  `nextConnId : IO.Ref Nat` for connection ID management.
- **`broadcastNodeSync`** pushes the serialized NODE list (`NODE...END\r\n`,
  no command header) to all registered sockets when `nodeMapVersion` changes.
- **`handleConnection`** detects version changes after `reconcileStep` via
  `modifyGet` (captures old version), then calls `broadcastNodeSync`.
- **Deferred registration**: sockets are added to `activeSockets` only AFTER the
  first `NodeAdd` event (via `registeredRef`), so the broadcast never interferes
  with the initial META handshake phase.

### Bridge.lean — Cleanup

- Removed broken `pushNodeSyncToPod` / `broadcastNodeSync` (kubectl exec hack).
- Removed unused `import FlareOperator.Flare.Protocol`.
- Changed `queryPodStats` from `sh -c ... | nc` to `bash -c ... /dev/tcp` since
  the flare-node container has `bash` but not `nc`.

### Main.lean — Cleanup

- Removed `lastVersionRef` and the reconcile-loop broadcast step (step 7).
  Topology broadcast is now handled entirely by TcpServer.lean.

### E2E/Helpers.lean — Added Missing Helper Functions

- `writeKeys` — write N keys via a single memcached entry point (proxy routing)
- `getPartitionMasterItems` — get `curr_items` from the master of a partition
- `getTotalItems` — get total items across all pods matching a label selector

---

## Current Blocker

The E2E test (`flare_e2e --filter failover`) fails at setup: **StatefulSet rollout
times out** because flared pods crash (CrashLoopBackOff).

### Root Cause Analysis

Two bugs were found and fixed:

1. **Protocol header hallucination (FIXED)**: The broadcast payload started with
   lowercase `node sync <version>\r\n`, which is a client request command. The
   flared parser only accepts uppercase tokens (`NODE`, `META`, `OK`, `END`).
   **Fix**: `broadcastNodeSync` now sends only `serializeNodeList cs.getNodes`
   (produces `NODE...\r\nEND\r\n`) with no command header.

2. **Early socket registration (FIXED)**: Sockets were registered for broadcast
   immediately on connection, before the META handshake completed. When another
   node's registration triggered a broadcast, the unregistered node received
   `NODE...` data during its META phase, causing `unknown first token [node]`.
   **Fix**: `registeredRef` defers registration until after first `NodeAdd`.

### Suspected Remaining Issue

Docker layer caching may be serving a stale binary. The `docker build` uses a
multi-stage build that copies source and runs `lake build` inside the container.
Cached layers from a previous build may prevent the latest fix from being picked up.

---

## TODO — Remaining Steps

### 1. Force Docker rebuild with no cache
```bash
cd /Users/junji.hashimoto/git/flare-operator
docker build --no-cache -t flare-operator:test -f Dockerfile.operator .
```
Force a no-cache rebuild to ensure the latest TcpServer.lean fix (removing
`node sync` header) is included in the binary.

### 2. Deploy and verify flared pods start correctly
```bash
# Deploy a minimal cluster manually
# Check: flared pods should reach Running/Ready without CrashLoopBackOff
# Check: operator logs show "[TRACE] Broadcast: pushed N nodes" messages
# Check: `stats nodes` on each pod shows the full topology (all nodes)
```

### 3. Run the E2E Failover test
```bash
cd flare_operator && .lake/build/bin/flare_e2e --filter failover
```
Expected results:
- Test 4 "write 100 keys via proxy routing": **PASS** (stored 100/100)
- Test 5 "verify key distribution (P0 > 0, P1 > 0, total = 100)": **PASS**
- All 11 tests should pass or skip gracefully

### 4. Commit the changes
```bash
git add flare_operator/FlareOperator/Server/TcpServer.lean \
       flare_operator/FlareOperator/K8s/Bridge.lean \
       flare_operator/FlareOperator/Main.lean \
       flare_operator/FlareOperator/E2E/Helpers.lean
git commit -m "Add native TCP topology broadcast to fix inconsistent node views"
```

### 5. Run other E2E test suites (optional)
- `flare_e2e --filter scale-out-slave`
- `flare_e2e --filter scale-out-master`
- `flare_e2e --filter scale-in-slave`

---

## Architecture: Topology Broadcast Flow

```
flared-0 ──TCP──┐
flared-1 ──TCP──┤  TcpServer (port 12120)
flared-2 ──TCP──┤
flared-3 ──TCP──┘
                │
                ├─ handleConnection (per socket)
                │   1. readLine → parseFlareCommand
                │   2. modifyGet(reconcileStep) → (oldVer, newState, response)
                │   3. sendResponse(sock, response)
                │   4. if NodeAdd && !registered → activeSockets.add(sock)
                │   5. if newState.nodeMapVersion != oldVer →
                │        broadcastNodeSync(all activeSockets)
                │          payload = NODE...END\r\n (no command header)
```

## Key Files

| File | Role |
|------|------|
| `FlareOperator/Server/TcpServer.lean` | TCP server + topology broadcast |
| `FlareOperator/K8s/Bridge.lean` | kubectl bridge (SIGHUP, pod queries) |
| `FlareOperator/Main.lean` | Reconcile loop (CRD, failover, services) |
| `FlareOperator/E2E/Helpers.lean` | Test helpers (writeKeys, getPartitionMasterItems) |
| `FlareOperator/Flare/Protocol.lean` | Wire format (serializeNode, serializeNodeList) |
| `FlareOperator/StateMachine/Reconciler.lean` | Pure state machine (reconcileStep) |
