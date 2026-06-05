#!/usr/bin/env bash
# test/e2e/phase16_http_server.sh — cljw's own HTTP server (ADR-0098).
# Starts the Ring demo fixture as a bg process, curls GET + POST, asserts the
# routed body + status (POST also guards the discardBody panic regression), then
# kills it. Serial (binds a fixed port). Skips cleanly if curl is unavailable.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "SKIP phase16_http_server (curl unavailable)"; exit 0; }
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
got=$(curl -s "http://127.0.0.1:$PORT/hello" 2>&1)
[[ "$got" == "GET /hello" ]] || fail "GET /hello body: got '$got'"
echo "PASS http-get-route -> $got"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/items" 2>&1)
[[ "$code" == "201" ]] || fail "POST status: got '$code' (discardBody panic regression?)"
echo "PASS http-post-201 -> $code"

# D-257: request :body / :query-string / :headers in the Ring map.
got=$(curl -s -X POST --data 'hello-body' "http://127.0.0.1:$PORT/echo" 2>&1)
[[ "$got" == "echo:hello-body" ]] || fail "POST /echo :body: got '$got'"
echo "PASS http-post-body -> $got"
got=$(curl -s "http://127.0.0.1:$PORT/q?a=1&b=2" 2>&1)
[[ "$got" == "q:a=1&b=2" ]] || fail "GET /q :query-string: got '$got'"
echo "PASS http-query-string -> $got"
got=$(curl -s -H "X-Test: v" "http://127.0.0.1:$PORT/h" 2>&1)
[[ "$got" == "h:v" ]] || fail "GET /h :headers: got '$got'"
echo "PASS http-header -> $got"

echo "OK — phase16_http_server (5 cases) green"
