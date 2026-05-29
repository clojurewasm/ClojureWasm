#!/usr/bin/env bash
# test/e2e/phase14_exit_smoke.sh
#
# §9.16 row 14.14 part (a) — Phase 14 / v0.1.0 exit smoke. One hit per
# v0.1.0 subcommand / surface to confirm the release cut is healthy.
# Deep per-surface coverage lives in the dedicated phase14_*.sh scripts
# (repl / nrepl / cljw_build / render_error / future_promise_delay /
# accessors / …); this is the consolidated "everything still starts and
# runs at the tag" check the release row calls for.
#
# nrepl is exercised by phase14_nrepl.sh (bencode driver); a shell smoke
# can't speak bencode cleanly, so it is referenced there, not re-driven.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- (1) -e eval surface ---
got=$("$BIN" -e '(+ 1 2)' 2>/dev/null) || fail "(1) eval: non-zero exit"
assert_eq 'eval_e' "$got" '3'

# --- (2) future / promise / delay (row 14.8) ---
got=$("$BIN" -e '(deref (future (+ 40 2)))' 2>/dev/null) || fail "(2) future: non-zero exit"
assert_eq 'future_deref' "$got" '42'
got=$("$BIN" -e '(deref (delay (* 3 3)))' 2>/dev/null) || fail "(2) delay: non-zero exit"
assert_eq 'delay_deref' "$got" '9'

# --- (3) host stdlib surface (java.util.UUID round-trips; 36-char str) ---
got=$("$BIN" -e '(count (str (java.util.UUID/randomUUID)))' 2>/dev/null) || fail "(3) host-stdlib: non-zero exit"
assert_eq 'host_uuid_strlen' "$got" '36'

# --- (4) binding / with-context (row 14.13) ---
got=$(printf '(require (quote [cljw.error :refer [with-context]]))\n(with-context {:a 1} cljw.error/*error-context*)\n' | "$BIN" - 2>/dev/null | tail -1) || fail "(4) with-context: non-zero exit"
assert_eq 'with_context' "$got" '{:a 1}'

# --- (5) cljw build round-trip: compile a .clj to a binary, run it ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '(println (+ 100 23))\n' > "$TMP/app.clj"
"$BIN" build "$TMP/app.clj" -o "$TMP/app" >/dev/null 2>&1 || fail "(5) build: compile failed"
got=$("$TMP/app" 2>/dev/null | tail -1) || fail "(5) build: run failed"
assert_eq 'build_roundtrip' "$got" '123'

# --- (6) cljw render-error decodes an EDN error event ---
printf '{:cljw/error true :kind :arithmetic_error :phase :eval :file "x" :line 1 :column 0 :message "Divide by zero"}\n' > "$TMP/err.log"
got=$("$BIN" render-error "$TMP/err.log" 2>/dev/null | grep -c "Divide by zero" || true)
[[ "$got" -ge 1 ]] || fail "(6) render-error: did not surface the message"
echo "PASS render_error -> surfaced message"

# --- (7) cljw repl reads a form from stdin and prints the result ---
got=$(printf '(+ 2 3)\n' | "$BIN" repl 2>/dev/null | grep -c '5' || true)
[[ "$got" -ge 1 ]] || fail "(7) repl: did not echo result 5"
echo "PASS repl_stdin -> 5"

# --- (8) cljw component build is gated (row 14.12, zwasm-v2) — must NOT
#         silently succeed; it exits non-zero ---
ec=0
"$BIN" component build "$TMP/app.clj" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || fail "(8) component build: unexpectedly succeeded (row 14.12 is gated)"
echo "PASS component_build_gated -> exit $ec"

echo
echo "Phase 14 / v0.1.0 exit smoke: all green."
