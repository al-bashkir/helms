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
RELAY_HOST="localhost"

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
  -subj "/CN=relay-e2e" \
  -addext "subjectAltName=DNS:${RELAY_HOST},IP:127.0.0.1" \
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

# The relay binary's startup self-test dials its own advertised URL with
# TLS verification enabled. With a self-signed cert it would refuse to
# start. Point Go's crypto/x509 at the cert so the loopback dial trusts
# it. Real users with cert-manager / Let's Encrypt don't need this.
log "Adding SSL_CERT_FILE to relay sidecar so it trusts the self-signed cert..."
kubectl -n "$NAMESPACE" set env deployment/"$RELEASE"-server -c relay \
  SSL_CERT_FILE=/etc/relay-tls/tls.crt

# This e2e exercises ONLY the relay sidecar additions in this chart. The
# management container in the same pod separately requires outbound
# internet (pkgs.netbird.io for the GeoIP database) which kind clusters
# typically lack — its readiness state is irrelevant to the relay TLS
# surface and is therefore not gated on here.
log "Waiting for the relay sidecar container to become Ready..."
for i in $(seq 1 60); do
  POD=$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/component=server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$POD" ]; then
    READY=$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="relay")].ready}' 2>/dev/null || true)
    if [ "$READY" = "true" ]; then
      log "  relay container Ready ✓"
      break
    fi
  fi
  if [ "$i" = "60" ]; then
    fail "relay container did not become Ready within 5 minutes"
  fi
  sleep 5
done

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

log "Verifying TLS handshake on TCP/33080 via port-forward..."
# The relay container image is distroless; run openssl from the host
# against a kubectl port-forward to the pod's relay listener.
POD=$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')
LOCAL_PORT=33180
kubectl -n "$NAMESPACE" port-forward "pod/$POD" "${LOCAL_PORT}:33080" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true; cleanup' EXIT
# Wait for port-forward to be listening
for i in $(seq 1 20); do
  if (echo > "/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null; then
    break
  fi
  sleep 0.5
done
HS=$(echo | timeout 5 openssl s_client -showcerts -connect "127.0.0.1:${LOCAL_PORT}" -servername "${RELAY_HOST}" 2>&1 || true)
kill $PF_PID 2>/dev/null || true
if ! echo "$HS" | grep -qE "subject=.*CN[ ]*=[ ]*relay-e2e"; then
  echo "$HS" >&2
  fail "openssl s_client did not negotiate TLS with the expected cert"
fi
log "  TLS handshake ✓"

log "E2E relay TLS test PASSED."
