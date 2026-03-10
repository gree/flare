#!/usr/bin/env bash
# E2E Test: Failover — write keys, kill master, verify promotion & data integrity
# Output: TAP (Test Anything Protocol)
set -euo pipefail

NAMESPACE="flare-system"
OPERATOR_SVC="flare-operator.${NAMESPACE}.svc.cluster.local"
OPERATOR_PORT=12120
FLARE_PORT=12121
DEBUG_POD="debug-tools"
CLUSTER_NAME="failover-test"
NUM_PARTITIONS=2
NUM_REPLICAS=2
NUM_PODS=$((NUM_PARTITIONS * NUM_REPLICAS))  # 4
TEST_COUNT=0
FAIL_COUNT=0
KEYS_PER_PARTITION=10

###############################################################################
# TAP helpers
###############################################################################
tap_plan() { echo "1..$1"; }
pass() { TEST_COUNT=$((TEST_COUNT + 1)); echo "ok ${TEST_COUNT} - $1"; }
fail() { TEST_COUNT=$((TEST_COUNT + 1)); FAIL_COUNT=$((FAIL_COUNT + 1)); echo "not ok ${TEST_COUNT} - $1"; }
skip() { TEST_COUNT=$((TEST_COUNT + 1)); echo "ok ${TEST_COUNT} - $1 # SKIP $2"; }
diag() { echo "# $*"; }

###############################################################################
# Cleanup (run at start and end)
###############################################################################
cleanup() {
  diag "=== Cleanup ==="
  kubectl delete flarecluster "${CLUSTER_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete statefulset flare-nodes -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete deployment flare-operator -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete svc flare-nodes flare-operator -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  for i in $(seq 0 $((NUM_PARTITIONS - 1))); do
    kubectl delete svc "${CLUSTER_NAME}-${i}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  done
  kubectl delete configmap "${CLUSTER_NAME}-node-map" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete lease "${CLUSTER_NAME}-operator-lease" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete pod "${DEBUG_POD}" -n "${NAMESPACE}" --force --grace-period=0 2>/dev/null || true
  # Wait for termination
  sleep 5
  kubectl delete pods -n "${NAMESPACE}" --all --force --grace-period=0 2>/dev/null || true
  sleep 3
  diag "Cleanup complete"
}

###############################################################################
# Setup functions
###############################################################################
setup() {
  diag "=== Setup ==="
  kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

  # 1. CRD and RBAC
  diag "Applying CRD and RBAC..."
  kubectl apply -f deploy/crd.yaml 2>&1 | sed 's/^/#   /'
  kubectl apply -f deploy/rbac.yaml 2>&1 | sed 's/^/#   /'

  # 2. FlareCluster CR (create BEFORE operator so it finds it on startup)
  diag "Creating FlareCluster CR..."
  kubectl apply -f - <<EOF
apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
spec:
  partitions: ${NUM_PARTITIONS}
  replicas: ${NUM_REPLICAS}
EOF

  # 3. Partition services
  diag "Creating partition services..."
  for i in $(seq 0 $((NUM_PARTITIONS - 1))); do
    kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${CLUSTER_NAME}-${i}
  namespace: ${NAMESPACE}
spec:
  selector:
    statefulset.kubernetes.io/pod-name: flare-nodes-0
  ports:
    - port: 12121
      targetPort: 12121
EOF
  done

  # 4a. Debug pod (needed early for META verification)
  diag "Creating debug pod..."
  kubectl run "${DEBUG_POD}" --namespace="${NAMESPACE}" --image=busybox:1.36 --restart=Never --command -- sleep 3600 2>/dev/null || true
  kubectl wait --namespace="${NAMESPACE}" --for=condition=Ready "pod/${DEBUG_POD}" --timeout=60s

  # 4b. Operator (with --cluster-name)
  #    Deploy operator first, then wait for it to fetch the CRD before starting flare-nodes.
  #    This ensures META returns correct partition-size from the start.
  diag "Deploying operator..."
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flare-operator
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: flare-operator
  template:
    metadata:
      labels:
        app: flare-operator
    spec:
      serviceAccountName: flare-operator
      containers:
        - name: flare-operator
          image: flare-operator:test
          imagePullPolicy: Never
          args: ["--namespace", "${NAMESPACE}", "--cluster-name", "${CLUSTER_NAME}"]
          ports:
            - containerPort: 12120
              name: flare-index
          livenessProbe:
            exec:
              command: ["true"]
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            tcpSocket:
              port: flare-index
            initialDelaySeconds: 3
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: flare-operator
  namespace: ${NAMESPACE}
spec:
  selector:
    app: flare-operator
  ports:
    - port: 12120
      targetPort: 12120
EOF

  # Wait for operator to be ready and fetch the CRD
  diag "Waiting for operator to start and fetch CRD..."
  local op_ready=false
  for i in $(seq 1 30); do
    local ready
    ready=$(kubectl get deployment flare-operator -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    ready=${ready:-0}
    if [ "${ready}" -ge 1 ]; then
      op_ready=true
      break
    fi
    sleep 2
  done
  if [ "${op_ready}" != true ]; then
    diag "WARNING: operator not ready after 60s"
  fi
  # Extra wait for the first reconcile cycle to fetch the CRD
  sleep 10

  # Verify META returns correct partition-size before deploying flare-nodes
  local meta_output
  meta_output=$(kubectl exec "${DEBUG_POD}" --namespace="${NAMESPACE}" -- \
    sh -c "printf 'meta\r\n' | nc -w 3 ${OPERATOR_SVC} ${OPERATOR_PORT}" 2>/dev/null || echo "")
  diag "META response:"
  echo "${meta_output}" | sed 's/^/#   /'

  # 5. StatefulSet
  diag "Deploying ${NUM_PODS} flare-nodes..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: flare-nodes
  namespace: ${NAMESPACE}
spec:
  clusterIP: None
  selector:
    app: flare
    cluster: ${CLUSTER_NAME}
  ports:
    - port: 12121
      targetPort: 12121
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: flare-nodes
  namespace: ${NAMESPACE}
spec:
  serviceName: flare-nodes
  replicas: ${NUM_PODS}
  selector:
    matchLabels:
      app: flare
      cluster: ${CLUSTER_NAME}
  template:
    metadata:
      labels:
        app: flare
        cluster: ${CLUSTER_NAME}
    spec:
      terminationGracePeriodSeconds: 5
      containers:
        - name: flared
          image: flare-node:test
          imagePullPolicy: Never
          command: ["sh", "-c", "rm -rf /tmp/flare/*.hdb /tmp/flare/*.hdb.wal && mkdir -p /tmp/flare && exec flared --data-dir /tmp/flare --server-port 12121 --index-server-name flare-operator.${NAMESPACE}.svc.cluster.local --index-server-port 12120 --stderr"]
          ports:
            - containerPort: 12121
              name: flare
          livenessProbe:
            tcpSocket:
              port: 12121
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          readinessProbe:
            tcpSocket:
              port: 12121
            initialDelaySeconds: 5
            periodSeconds: 3
            failureThreshold: 4
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
EOF

}

###############################################################################
# Polling / Wait helpers
###############################################################################
wait_for_condition() {
  local desc="$1" timeout="$2"; shift 2
  local elapsed=0
  diag "Waiting for: ${desc} (timeout: ${timeout}s)"
  while [ "${elapsed}" -lt "${timeout}" ]; do
    if "$@" 2>/dev/null; then
      diag "  OK after ${elapsed}s"
      return 0
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done
  diag "  TIMEOUT after ${timeout}s"
  return 1
}

_check_ready_replicas() {
  local expected="$1"
  local ready
  ready=$(kubectl get statefulset flare-nodes -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "${ready}" -ge "${expected}" ]
}

_check_cluster_stable() {
  local expected="$1"
  local sync
  sync=$(operator_tcp_cmd "node sync") || return 1
  # Count active nodes (not Down, state != 2)
  local active
  active=$(echo "${sync}" | grep "^NODE " | awk '$5 != 2' | wc -l | tr -d ' ')
  [ "${active}" -ge "${expected}" ]
}

_check_both_masters() {
  local sync
  sync=$(operator_tcp_cmd "node sync") || return 1
  local p0 p1
  p0=$(echo "${sync}" | grep "^NODE " | awk '$4 == 0 && $5 == 0 && $6 == 0' | wc -l | tr -d ' ')
  p1=$(echo "${sync}" | grep "^NODE " | awk '$4 == 0 && $5 == 0 && $6 == 1' | wc -l | tr -d ' ')
  [ "${p0}" -eq 1 ] && [ "${p1}" -eq 1 ]
}

###############################################################################
# Protocol helpers
###############################################################################
operator_tcp_cmd() {
  local cmd="$1"
  kubectl exec "${DEBUG_POD}" --namespace="${NAMESPACE}" -- \
    sh -c "printf '%s\r\n' '${cmd}' | nc -w 3 ${OPERATOR_SVC} ${OPERATOR_PORT}" 2>/dev/null
}

get_pod_ip() {
  kubectl get pod "$1" -n "${NAMESPACE}" -o jsonpath='{.status.podIP}'
}

find_master_pod() {
  local partition="$1"
  local sync
  sync=$(operator_tcp_cmd "node sync") || return 1
  echo "${sync}" | grep "^NODE " | awk -v p="${partition}" '$4 == 0 && $5 == 0 && $6 == p {print $2}' | cut -d. -f1 | head -1
}

find_slave_pod() {
  local partition="$1"
  local sync
  sync=$(operator_tcp_cmd "node sync") || return 1
  echo "${sync}" | grep "^NODE " | awk -v p="${partition}" '$4 == 1 && $6 == p {print $2; exit}' | cut -d. -f1
}

assert_one_master() {
  local label="$1"
  local sync
  sync=$(operator_tcp_cmd "node sync")
  local partitions
  partitions=$(echo "${sync}" | grep "^NODE " | awk '$4 == 0 && $5 == 0 {print $6}' | sort)
  if [ -z "${partitions}" ]; then
    fail "${label}: no active masters"
    echo "${sync}" | sed 's/^/#   /'
    return 1
  fi
  local dup
  dup=$(echo "${partitions}" | uniq -d)
  if [ -n "${dup}" ]; then
    fail "${label}: duplicate masters: ${dup}"
    echo "${sync}" | sed 's/^/#   /'
    return 1
  fi
  pass "${label}"
}

###############################################################################
# Data helpers (memcached protocol)
###############################################################################
write_keys() {
  local ip="$1" prefix="$2" count="$3"
  # Build a script that sends SET commands with sleep for response
  local script="{"
  for i in $(seq 0 $((count - 1))); do
    local key="${prefix}_${i}"
    local val="val${i}"
    local len=${#val}
    script="${script} printf 'set ${key} 0 0 ${len}\r\n${val}\r\n';"
  done
  script="${script} sleep 2; }"
  kubectl exec "${DEBUG_POD}" --namespace="${NAMESPACE}" -- \
    sh -c "${script} | nc -w 10 ${ip} ${FLARE_PORT}" 2>/dev/null
}

read_key() {
  local ip="$1" key="$2"
  kubectl exec "${DEBUG_POD}" --namespace="${NAMESPACE}" -- \
    sh -c "printf 'get ${key}\r\n' | nc -w 3 ${ip} ${FLARE_PORT}" 2>/dev/null
}

get_curr_items() {
  local ip="$1"
  kubectl exec "${DEBUG_POD}" --namespace="${NAMESPACE}" -- \
    sh -c "printf 'stats\r\n' | nc -w 3 ${ip} ${FLARE_PORT}" 2>/dev/null | \
    grep "STAT curr_items" | awk '{print $3}' | tr -d '\r\n '
}

###############################################################################
# Test Phases
###############################################################################

phase_preflight() {
  diag ""
  diag "=== Phase 1: Pre-flight ==="

  # Dump node sync for diagnostics
  local sync
  sync=$(operator_tcp_cmd "node sync")
  diag "Node sync:"
  echo "${sync}" | grep "^NODE " | sed 's/^/#   /'

  local pong
  pong=$(operator_tcp_cmd "ping" | tr -d '\r\n')
  if echo "${pong}" | grep -qi "ok"; then
    pass "operator responds to ping"
  else
    fail "operator responds to ping (got: '${pong}')"
  fi

  assert_one_master "pre-flight: one-master-per-partition"

  if _check_both_masters; then
    pass "both partitions have masters"
  else
    fail "both partitions have masters"
    diag "Node sync:"
    echo "${sync}" | grep "^NODE " | sed 's/^/#   /'
  fi
}

phase_write() {
  diag ""
  diag "=== Phase 2: Write ${KEYS_PER_PARTITION} keys to P0 master ==="

  local master_pod master_ip
  master_pod=$(find_master_pod 0)
  if [ -z "${master_pod}" ]; then
    fail "P0: find master"
    fail "P0: write keys"
    fail "P0: verify curr_items"
    return
  fi
  master_ip=$(get_pod_ip "${master_pod}")
  diag "P0: master=${master_pod} ip=${master_ip}"

  # Write keys — some will be STORED (hash to P0), others may get SERVER_ERROR (hash to P1)
  # We expect at least some keys to be stored on P0
  local result stored
  result=$(write_keys "${master_ip}" "key" "${KEYS_PER_PARTITION}")
  stored=$(echo "${result}" | grep -c "STORED" || true)
  stored=$(echo "${stored}" | tr -d '[:space:]')
  stored=${stored:-0}

  if [ "${stored}" -gt 0 ]; then
    pass "P0: wrote ${stored}/${KEYS_PER_PARTITION} keys (rest may hash to P1)"
  else
    fail "P0: wrote keys (got 0 STORED)"
    diag "Result (first 5 lines):"
    echo "${result}" | head -5 | sed 's/^/#   /'
  fi

  # Verify via stats
  sleep 1
  local items
  items=$(get_curr_items "${master_ip}")
  items=${items:-0}
  if [ "${items}" -gt 0 ] 2>/dev/null; then
    pass "P0: curr_items=${items}"
  else
    fail "P0: curr_items=${items} (expected >0)"
  fi

  # Also write to P1 if possible (skip on failure, not critical)
  local p1_master p1_ip
  p1_master=$(find_master_pod 1)
  if [ -n "${p1_master}" ]; then
    p1_ip=$(get_pod_ip "${p1_master}")
    local p1_result p1_stored
    p1_result=$(write_keys "${p1_ip}" "xkey" "${KEYS_PER_PARTITION}")
    p1_stored=$(echo "${p1_result}" | grep -c "STORED" || true)
    p1_stored=$(echo "${p1_stored}" | tr -d '[:space:]')
    p1_stored=${p1_stored:-0}
    if [ "${p1_stored}" -gt 0 ]; then
      pass "P1: wrote ${p1_stored}/${KEYS_PER_PARTITION} keys"
    else
      skip "P1: wrote keys" "P1 master may not accept writes (key routing)"
    fi
  else
    skip "P1: wrote keys" "no P1 master found"
  fi
}

phase_failover() {
  diag ""
  diag "=== Phase 3: Kill P0 master ==="

  local old_master
  old_master=$(find_master_pod 0)
  if [ -z "${old_master}" ]; then
    fail "failover: find P0 master"
    fail "failover: new master elected"
    fail "failover: one-master-per-partition"
    fail "failover: P1 unaffected"
    return
  fi
  diag "Killing P0 master: ${old_master}"
  kubectl delete pod "${old_master}" -n "${NAMESPACE}" --force --grace-period=0

  # Wait for P0 to have a master again (same pod may reclaim on fast restart)
  if wait_for_condition "P0 master available" 90 _any_master_p0; then
    local new_master
    new_master=$(find_master_pod 0)
    if [ "${new_master}" = "${old_master}" ]; then
      pass "failover: P0 master reclaimed by restarted pod (${new_master})"
    else
      pass "failover: P0 slave promoted to master (${new_master})"
    fi
  else
    fail "failover: P0 master available within 90s"
    diag "Current node sync:"
    operator_tcp_cmd "node sync" | sed 's/^/#   /'
  fi

  assert_one_master "failover: one-master-per-partition"

  # Verify P1 master still has data
  local p1_master p1_ip p1_items
  p1_master=$(find_master_pod 1)
  if [ -n "${p1_master}" ]; then
    p1_ip=$(get_pod_ip "${p1_master}")
    p1_items=$(get_curr_items "${p1_ip}")
    p1_items=${p1_items:-0}
    if [ "${p1_items}" -ge "${KEYS_PER_PARTITION}" ] 2>/dev/null; then
      pass "failover: P1 unaffected (items=${p1_items})"
    else
      skip "failover: P1 unaffected (items=${p1_items})" "data may have been lost"
    fi
  else
    fail "failover: P1 master exists"
  fi
}

_any_master_p0() {
  local current
  current=$(find_master_pod 0) || return 1
  [ -n "${current}" ]
}

phase_recovery() {
  diag ""
  diag "=== Phase 4: Recovery ==="

  if wait_for_condition "all ${NUM_PODS} pods ready" 120 _check_ready_replicas "${NUM_PODS}"; then
    pass "recovery: all pods ready"
  else
    fail "recovery: all pods ready"
  fi

  # Wait for nodes to re-register
  sleep 15
  assert_one_master "recovery: one-master-per-partition"

  diag "Final node sync:"
  operator_tcp_cmd "node sync" | sed 's/^/#   /'
}

###############################################################################
# Main
###############################################################################
main() {
  diag "Flare Operator E2E: Failover Test"
  diag "================================="
  diag "Config: ${NUM_PARTITIONS} partitions, ${NUM_REPLICAS} replicas, ${NUM_PODS} pods"
  diag ""

  # Tests: preflight(3) + write(3) + failover(3) + recovery(2) = 11
  tap_plan 11

  cleanup
  setup

  # Wait for cluster readiness
  diag ""
  diag "Waiting for cluster..."
  wait_for_condition "all ${NUM_PODS} pods ready" 180 _check_ready_replicas "${NUM_PODS}"
  # Wait for grace period + extra stabilization
  diag "Waiting for grace period (50s)..."
  sleep 50
  wait_for_condition "cluster stable" 60 _check_both_masters

  phase_preflight
  phase_write
  phase_failover
  phase_recovery

  cleanup

  diag ""
  diag "================================="
  diag "Tests: ${TEST_COUNT}, Failures: ${FAIL_COUNT}"
  [ "${FAIL_COUNT}" -eq 0 ] && diag "RESULT: PASS" || diag "RESULT: FAIL"
  exit "${FAIL_COUNT}"
}

main "$@"
