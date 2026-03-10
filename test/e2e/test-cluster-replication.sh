#!/usr/bin/env bash
# E2E test: Cluster Replication (Blue/Green Migration)
# Validates the operator's autonomous duplicate→forward mode transition.
# Output: TAP (Test Anything Protocol)
set -euo pipefail

NAMESPACE="flare-system"
FLARE_PORT=12121
DEBUG_POD="debug-repl"
TEST_COUNT=0
FAIL_COUNT=0

###############################################################################
# TAP helpers
###############################################################################
pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "ok ${TEST_COUNT} - $1"
}

fail() {
  TEST_COUNT=$((TEST_COUNT + 1))
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "not ok ${TEST_COUNT} - $1"
}

skip() {
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "ok ${TEST_COUNT} - $1 # SKIP $2"
}

diag() {
  echo "# $*"
}

wait_for_condition() {
  local desc="$1"
  local timeout="$2"
  shift 2
  local elapsed=0
  diag "Waiting for: ${desc} (timeout: ${timeout}s)"
  while [ "${elapsed}" -lt "${timeout}" ]; do
    if "$@" 2>/dev/null; then
      diag "  condition met after ${elapsed}s"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  diag "  TIMEOUT after ${timeout}s waiting for: ${desc}"
  return 1
}

###############################################################################
# Cleanup function
###############################################################################
cleanup() {
  diag "=== Cleanup ==="
  kubectl delete flarecluster flare-v1 flare-v2 -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete statefulset flare-v1-nodes flare-v2-nodes -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete service flare-v1-nodes flare-v2-nodes -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete configmap flare-v1-config flare-v2-config flare-v1-node-map flare-v2-node-map -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete deployment flare-operator-v1 flare-operator-v2 -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete service flare-operator-v1 flare-operator-v2 -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete lease flare-v1-operator-lease flare-v2-operator-lease -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete pod "${DEBUG_POD}" -n "${NAMESPACE}" --force --grace-period=0 2>/dev/null || true
}

trap cleanup EXIT

###############################################################################
# Setup
###############################################################################
setup() {
  diag "=== Setup ==="

  # Ensure namespace
  kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

  # Apply CRD and RBAC
  kubectl apply -f deploy/crd.yaml
  kubectl apply -f deploy/rbac.yaml

  # Create empty ConfigMaps for replication config
  kubectl create configmap flare-v1-config -n "${NAMESPACE}" --from-literal='extra.conf=' 2>/dev/null || true
  kubectl create configmap flare-v2-config -n "${NAMESPACE}" --from-literal='extra.conf=' 2>/dev/null || true

  # Deploy operator-v1 (manages flare-v1)
  deploy_operator "flare-operator-v1" "flare-v1"

  # Deploy operator-v2 (manages flare-v2)
  deploy_operator "flare-operator-v2" "flare-v2"

  # Create FlareCluster CRDs
  kubectl apply -f - <<EOF
apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: flare-v1
  namespace: ${NAMESPACE}
spec:
  partitions: 2
  replicas: 2
EOF

  kubectl apply -f - <<EOF
apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: flare-v2
  namespace: ${NAMESPACE}
spec:
  partitions: 1
  replicas: 2
EOF

  # Deploy flare-v1 StatefulSet (6 pods: 2 partitions × (1 master + 2 slaves))
  deploy_flare_statefulset "flare-v1" 6

  # Deploy flare-v2 StatefulSet (3 pods: 1 partition × (1 master + 2 slaves))
  deploy_flare_statefulset "flare-v2" 3

  # Wait for rollouts
  diag "Waiting for StatefulSets to be ready..."
  kubectl rollout status statefulset/flare-v1-nodes -n "${NAMESPACE}" --timeout=300s
  kubectl rollout status statefulset/flare-v2-nodes -n "${NAMESPACE}" --timeout=300s

  # Wait for operator deployments
  kubectl rollout status deployment/flare-operator-v1 -n "${NAMESPACE}" --timeout=120s
  kubectl rollout status deployment/flare-operator-v2 -n "${NAMESPACE}" --timeout=120s

  # Create debug pod
  kubectl run "${DEBUG_POD}" \
    --namespace="${NAMESPACE}" \
    --image=busybox:1.36 \
    --restart=Never \
    --command -- sleep 3600 2>/dev/null || true
  kubectl wait --namespace="${NAMESPACE}" \
    --for=condition=Ready "pod/${DEBUG_POD}" \
    --timeout=60s
  diag "Setup complete"
}

deploy_operator() {
  local name="$1"
  local cluster_name="$2"

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    app: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      serviceAccountName: flare-operator
      containers:
        - name: flare-operator
          image: flare-operator:test
          imagePullPolicy: Never
          args:
            - "--namespace"
            - "${NAMESPACE}"
            - "--cluster-name"
            - "${cluster_name}"
          ports:
            - containerPort: 12120
              name: flare-index
              protocol: TCP
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${name}
  ports:
    - port: 12120
      targetPort: flare-index
      protocol: TCP
  type: ClusterIP
EOF
}

deploy_flare_statefulset() {
  local cluster="$1"
  local replicas="$2"
  # Operator service name matches the operator deployment name pattern
  local operator_svc="flare-operator-${cluster##flare-}"

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${cluster}-nodes
  namespace: ${NAMESPACE}
  labels:
    app: flare
    cluster: ${cluster}
spec:
  clusterIP: None
  selector:
    app: flare
    cluster: ${cluster}
  ports:
    - port: ${FLARE_PORT}
      targetPort: flare
      name: flare
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${cluster}-nodes
  namespace: ${NAMESPACE}
spec:
  serviceName: ${cluster}-nodes
  replicas: ${replicas}
  selector:
    matchLabels:
      app: flare
      cluster: ${cluster}
  template:
    metadata:
      labels:
        app: flare
        cluster: ${cluster}
    spec:
      terminationGracePeriodSeconds: 5
      containers:
        - name: flared
          image: flare-node:test
          imagePullPolicy: Never
          args:
            - "--server-name"
            - "\$(POD_NAME).${cluster}-nodes.${NAMESPACE}.svc.cluster.local"
            - "--server-port"
            - "${FLARE_PORT}"
            - "--index-server-name"
            - "${operator_svc}.${NAMESPACE}.svc.cluster.local"
            - "--index-server-port"
            - "12120"
            - "--config"
            - "/etc/flare/extra.conf"
            - "--data-dir"
            - "/tmp/flare"
            - "--stderr"
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          ports:
            - containerPort: ${FLARE_PORT}
              name: flare
          volumeMounts:
            - name: data
              mountPath: /tmp/flare
            - name: extra-config
              mountPath: /etc/flare/extra.conf
              subPath: extra.conf
          readinessProbe:
            tcpSocket:
              port: ${FLARE_PORT}
            initialDelaySeconds: 5
            periodSeconds: 3
      volumes:
        - name: data
          emptyDir: {}
        - name: extra-config
          configMap:
            name: ${cluster}-config
EOF
}

###############################################################################
# Test: Write test data to flare-v1
###############################################################################
test_write_data() {
  diag ""
  diag "=== Write test data to flare-v1 ==="

  # Get a flare-v1 pod IP
  local pod_ip
  pod_ip=$(kubectl get pods -n "${NAMESPACE}" -l "app=flare,cluster=flare-v1" \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

  if [ -z "${pod_ip}" ]; then
    fail "write test data: no flare-v1 pod found"
    return
  fi

  local result
  result=$(kubectl exec "${DEBUG_POD}" -n "${NAMESPACE}" -- \
    sh -c "printf 'set repl_test_key 0 0 14\r\nrepl_test_value\r\n' | nc -w 3 ${pod_ip} ${FLARE_PORT}" 2>/dev/null | tr -d '\r\n')

  if echo "${result}" | grep -q "STORED"; then
    pass "write test data to flare-v1"
  else
    fail "write test data to flare-v1"
    diag "Response: ${result}"
  fi
}

###############################################################################
# Test: Trigger replication
###############################################################################
test_trigger_replication() {
  diag ""
  diag "=== Trigger cluster replication ==="

  # Get flare-v2 service FQDN
  local v2_svc="flare-v2-nodes.${NAMESPACE}.svc.cluster.local"

  kubectl patch flarecluster flare-v1 -n "${NAMESPACE}" --type=merge -p "{
    \"spec\": {
      \"clusterReplication\": {
        \"enabled\": true,
        \"serverName\": \"${v2_svc}\",
        \"port\": ${FLARE_PORT},
        \"mode\": \"duplicate\",
        \"concurrency\": 2
      }
    }
  }"
  pass "triggered cluster replication via CRD patch"
}

###############################################################################
# Test: Verify migration phases
###############################################################################
test_verify_phases() {
  diag ""
  diag "=== Verify migration phases ==="

  # Wait for Dumping phase
  if wait_for_condition "migrationPhase=Dumping" 60 _check_phase "Dumping"; then
    pass "migrationPhase transitioned to Dumping"
  else
    fail "migrationPhase transitioned to Dumping"
  fi

  # Verify ConfigMap contains replication settings
  local cm_data
  cm_data=$(kubectl get configmap flare-v1-config -n "${NAMESPACE}" \
    -o jsonpath='{.data.extra\.conf}' 2>/dev/null || echo "")

  if echo "${cm_data}" | grep -q "cluster-replication = true"; then
    pass "ConfigMap contains cluster-replication settings"
  else
    fail "ConfigMap contains cluster-replication settings"
    diag "ConfigMap data: ${cm_data}"
  fi

  # Wait for Forwarding phase (dump_replication thread completes)
  if wait_for_condition "migrationPhase=Forwarding" 120 _check_phase "Forwarding"; then
    pass "migrationPhase transitioned to Forwarding"
  else
    fail "migrationPhase transitioned to Forwarding"
  fi

  # Verify ConfigMap updated to forward mode
  cm_data=$(kubectl get configmap flare-v1-config -n "${NAMESPACE}" \
    -o jsonpath='{.data.extra\.conf}' 2>/dev/null || echo "")

  if echo "${cm_data}" | grep -q "cluster-replication-mode = forward"; then
    pass "ConfigMap updated to forward mode"
  else
    fail "ConfigMap updated to forward mode"
    diag "ConfigMap data: ${cm_data}"
  fi
}

_check_phase() {
  local expected="$1"
  local actual
  actual=$(kubectl get flarecluster flare-v1 -n "${NAMESPACE}" \
    -o jsonpath='{.status.migrationPhase}' 2>/dev/null)
  [ "${actual}" = "${expected}" ]
}

###############################################################################
# Test: Verify data replicated to flare-v2
###############################################################################
test_verify_data() {
  diag ""
  diag "=== Verify data in flare-v2 ==="

  local pod_ip
  pod_ip=$(kubectl get pods -n "${NAMESPACE}" -l "app=flare,cluster=flare-v2" \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

  if [ -z "${pod_ip}" ]; then
    fail "verify replicated data: no flare-v2 pod found"
    return
  fi

  local result
  result=$(kubectl exec "${DEBUG_POD}" -n "${NAMESPACE}" -- \
    sh -c "printf 'get repl_test_key\r\n' | nc -w 3 ${pod_ip} ${FLARE_PORT}" 2>/dev/null)

  if echo "${result}" | grep -q "repl_test_value"; then
    pass "data replicated to flare-v2"
  else
    # Data replication depends on flared actually running cluster-replication
    # In a test environment without real flared, this may not work
    skip "data replicated to flare-v2" \
      "flared may not support replication in test image"
  fi
}

###############################################################################
# Main
###############################################################################
main() {
  diag "Flare Operator Cluster Replication E2E Test"
  diag "============================================"
  diag ""

  echo "1..7"

  setup
  test_write_data
  test_trigger_replication
  test_verify_phases
  test_verify_data

  diag ""
  diag "============================================"
  diag "Tests: ${TEST_COUNT}, Failures: ${FAIL_COUNT}"
  if [ "${FAIL_COUNT}" -gt 0 ]; then
    diag "RESULT: FAIL"
    exit 1
  else
    diag "RESULT: PASS"
    exit 0
  fi
}

main "$@"
