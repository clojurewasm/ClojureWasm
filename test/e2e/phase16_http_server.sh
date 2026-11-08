#!/usr/bin/env bash
# e2e-process-boundary: starts cljw's HTTP server as a background process and drives it with curl
# test/e2e/phase16_http_server.sh — cljw's own HTTP server (ADR-0098).
# Starts the Ring demo fixture as a bg process, curls GET + POST, asserts the
# routed body + status (POST also guards the discardBody panic regression), then
# kills it. Serial (binds a fixed port). Skips cleanly if curl is unavailable.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

# Portable bounded run: GNU `timeout`, else coreutils `gtimeout`, else
# unbounded (hosted mac runners ship neither; same pattern as
# scripts/corpus_regression.clj).
run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}
command -v curl >/dev/null 2>&1 || { echo "SKIP phase16_http_server (curl unavailable)"; exit 0; }
PORT=8157
run_bounded 25 "$BIN" test/e2e/fixtures/http_server_demo.clj >/dev/null 2>&1 &
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

# Response :headers map → Content-Type + custom header written verbatim.
hdrs=$(curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/html" 2>&1)
grep -qi "^content-type: text/html; charset=utf-8" <<<"$hdrs" || fail "resp :headers content-type: got '$hdrs'"
grep -qi "^x-custom: yes" <<<"$hdrs" || fail "resp :headers x-custom: got '$hdrs'"
echo "PASS http-resp-headers -> content-type+x-custom"
body=$(curl -s "http://127.0.0.1:$PORT/html" 2>&1)
[[ "$body" == "<h1>hi</h1>" ]] || fail "GET /html body: got '$body'"
echo "PASS http-html-body -> $body"

# A primitive byte-array :body is served verbatim: 256 bytes, one of each
# value 0..255. A UTF-8 path would expand bytes >= 0x80 and grow the body.
BLEN=$(curl -s "http://127.0.0.1:$PORT/bytes" | wc -c | tr -d ' ')
[[ "$BLEN" == "256" ]] || fail "GET /bytes length: got $BLEN, want 256"
BOD=$(curl -s "http://127.0.0.1:$PORT/bytes" | od -An -tu1 | tr -s ' ')
EXP=""
for i in $(seq 0 255); do EXP="$EXP $i"; done
[[ "$(echo $BOD)" == "$(echo $EXP)" ]] || fail "GET /bytes content mismatch"
echo "PASS http-bytes-body -> 256 verbatim bytes"

# NINE response headers — a >8-entry :headers map promotes to hash_map
# (Discussion #12 bug class) and used to be dropped wholesale.
hdrs=$(curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/many-headers" 2>&1)
grep -qi "^x-m1: 1" <<<"$hdrs" || fail "9-resp-headers x-m1: got '$hdrs'"
grep -qi "^x-m9: 9" <<<"$hdrs" || fail "9-resp-headers x-m9: got '$hdrs'"
echo "PASS http-9-resp-headers -> x-m1..x-m9"

# FIX-2 (SE-4): an out-of-range :status (200000 > 1023) must fall back to 500,
# NOT panic the whole server process. Assert 500 AND that the server survives (a
# follow-up request still routes).
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/badstatus" 2>&1)
[[ "$code" == "500" ]] || fail "out-of-range :status: got '$code' (expected 500 fallback; @intCast panic?)"
echo "PASS http-badstatus-500 -> $code"
got=$(curl -s "http://127.0.0.1:$PORT/still-alive" 2>&1)
[[ "$got" == "GET /still-alive" ]] || fail "server died after bad :status: got '$got'"
echo "PASS http-survives-badstatus -> $got"

# SE-5: a header value with CRLF must NOT split the response (header injection).
# cljw rejects the dirty header at the boundary → 500, and the injected
# "Set-Cookie: pwned" must NOT appear anywhere in the response headers.
resp=$(curl -s -D - "http://127.0.0.1:$PORT/crlf-header" 2>&1)
grep -qi "Set-Cookie: pwned" <<<"$resp" && fail "SE-5 header injection: Set-Cookie reflected:
$resp"
echo "PASS http-crlf-no-injection -> no Set-Cookie"
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/crlf-header" 2>&1)
[[ "$code" == "500" ]] || fail "SE-5 dirty header: got '$code' (expected 500 rejection)"
echo "PASS http-crlf-header-500 -> $code"
got=$(curl -s "http://127.0.0.1:$PORT/still-alive" 2>&1)
[[ "$got" == "GET /still-alive" ]] || fail "server died after CRLF header: got '$got'"
echo "PASS http-survives-crlf -> $got"

# D-339 (SE-3, slowloris): a client that opens a connection and never finishes
# sending the request head must NOT wedge the server. The accept loop is serial
# by design, so a half-open connection blocks every other client for as long as
# the read blocks — without a deadline, that is forever, and one packet DoSes a
# public deploy. The fixture sets :header-timeout-ms 1500, so the stalled
# connection must be dropped and the next client served well inside 15s.
#
# The stalled client runs in a SUBSHELL, not via `exec` on the parent: a
# redirection failure on `exec` is fatal to a non-interactive shell, which would
# take the whole suite down on a host without bash /dev/tcp.
if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
  # Writes a partial head (no terminating blank line) and holds the connection.
  ( printf 'GET /still-alive HTTP/1.1\r\nHost: localhost\r\n'; sleep 12 ) \
      >/dev/tcp/127.0.0.1/$PORT 2>/dev/null &
  SLOW=$!
  sleep 0.5   # let the stalled client reach the accept loop first
  start=$(date +%s)
  got=$(run_bounded 15 curl -s --max-time 12 "http://127.0.0.1:$PORT/still-alive" 2>&1 || true)
  elapsed=$(( $(date +%s) - start ))
  kill "$SLOW" 2>/dev/null || true
  wait "$SLOW" 2>/dev/null || true
  [[ "$got" == "GET /still-alive" ]] || fail "slowloris wedged the server (D-339): got '$got' after ${elapsed}s"
  # The elapsed bound is the real assertion. Without a header deadline the
  # server serves this request only when the ATTACKER disconnects (12s here),
  # which still "passes" a body-only check — so assert the deadline did the
  # work: 1500ms fixture timeout + dispatch must land well under 5s.
  [[ "$elapsed" -lt 5 ]] || fail "slowloris blocked the server for ${elapsed}s (D-339: no header deadline; it was the attacker giving up, not the server recovering)"
  echo "PASS http-slowloris-recovers -> served in ${elapsed}s"
else
  echo "SKIP http-slowloris (bash /dev/tcp unavailable)"
fi

echo "OK — phase16_http_server (14 cases) green"
