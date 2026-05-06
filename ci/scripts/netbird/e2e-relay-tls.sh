#!/usr/bin/env bash
#
# E2E test for relay TLS on a kind cluster.
#
# Generates a self-signed cert, creates a `kubernetes.io/tls` Secret,
# installs the netbird chart with relay TLS enabled, and verifies:
#   - the pod becomes Ready
#   - the relay container log no longer contains "Not starting QUIC listener"
#   - the relay container listens TLS on TCP/33080
#   - the relay container listens UDP on 33080 (relay-quic port present)
#
set -euo pipefail

RELEASE="netbird-relay-tls-e2e"
NAMESPACE="netbird-relay-tls-e2e"
CHART="charts/netbird"
VALUES_FILE="$CHART/ci/e2e-values-relay-tls.yaml"
TIMEOUT="10m"

log()  { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    log "Exit $rc — leaving cluster state for debug."
    kubectl -n "$NAMESPACE" get pods -o wide || true
    kubectl -n "$NAMESPACE" logs deploy/"$RELEASE"-server -c relay --tail=200 || true
    return
  fi
  log "Cleaning up..."
  helm uninstall "$RELEASE" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

log "Creating namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

log "Generating self-signed cert..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' RETURN
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=relay.test" \
  -keyout "$TMPDIR/tls.key" \
  -out "$TMPDIR/tls.crt"

log "Creating relay-tls-selfsigned Secret..."
kubectl -n "$NAMESPACE" create secret tls relay-tls-selfsigned \
  --cert="$TMPDIR/tls.crt" --key="$TMPDIR/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Installing netbird chart with relay TLS enabled..."
if ! helm install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --timeout "$TIMEOUT"; then
  fail "Helm install failed"
fi

log "Waiting for the server deployment to roll out..."
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-server --timeout=300s

log "Verifying QUIC listener WARN is absent from relay logs..."
RELAY_LOG=$(kubectl -n "$NAMESPACE" logs deploy/"$RELEASE"-server -c relay --tail=500)
if echo "$RELAY_LOG" | grep -q "Not starting QUIC listener"; then
  echo "Relay log:" >&2
  echo "$RELAY_LOG" >&2
  fail "Relay log still contains the 'Not starting QUIC listener' warning"
fi
log "  WARN absent ✓"

log "Verifying relay-quic UDP container port is declared..."
PORTS=$(kubectl -n "$NAMESPACE" get deploy "$RELEASE"-server -o json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); ps=[c['ports'] for c in d['spec']['template']['spec']['containers'] if c['name']=='relay'][0]; print(' '.join(p['name'] for p in ps))")
if ! echo "$PORTS" | grep -qw "relay-quic"; then
  fail "relay container does not declare a relay-quic port (got: $PORTS)"
fi
log "  relay-quic port declared ✓"

log "Verifying TLS handshake on TCP/33080 from inside the cluster..."
POD=$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')
HS=$(kubectl -n "$NAMESPACE" exec "$POD" -c relay -- /bin/sh -c \
  'echo | timeout 5 openssl s_client -connect localhost:33080 -servername relay.test 2>&1' || true)
if ! echo "$HS" | grep -qE "subject=.*CN[ ]*=[ ]*relay.test"; then
  echo "$HS" >&2
  fail "openssl s_client did not negotiate TLS with the expected CN"
fi
log "  TLS handshake ✓"

log "E2E relay TLS test PASSED."
