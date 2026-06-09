#!/usr/bin/env bash
# test/e2e/phase16_http_client.sh — cljw's outbound HTTP client (D-257 discharged).
# Hermetic localhost round-trip: start cljw's OWN HTTP server (http_server_demo)
# as a bg process, then drive it with cljw's OWN http client (cljw.http.client) and
# assert the captured status/body. No external network (HTTPS/TLS is verified
# manually, not in the gate). Serial (binds a fixed port).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "SKIP phase16_http_client (curl unavailable for readiness poll)"; exit 0; }

PORT=8157
timeout 25 "$BIN" test/e2e/fixtures/http_server_demo.clj >/dev/null 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true; pkill -f http_server_demo.clj 2>/dev/null || true' EXIT

# Wait for the listener (poll up to ~4s).
up=0
for _ in $(seq 1 40); do
  if curl -s "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then up=1; break; fi
  sleep 0.1
done
[[ "$up" == 1 ]] || fail "server did not come up on :$PORT"

out="$("$BIN" test/e2e/fixtures/http_client_probe.clj 2>&1)" || fail "client probe exited non-zero:
$out"
echo "$out" | grep -q "PASS http-client-get"       || fail "client GET status/body:
$out"
echo "$out" | grep -q "PASS http-client-query"     || fail "client query-string:
$out"
echo "$out" | grep -q "PASS http-client-post-body" || fail "client POST body:
$out"
echo "$out" | grep -q "NOT-CAUGHT" && fail "a client error escaped (catch …):
$out"
echo "$out" | grep -q "^DONE$"     || fail "client probe did not complete:
$out"

echo "OK — phase16_http_client (get/query/post + catchable error) green"
