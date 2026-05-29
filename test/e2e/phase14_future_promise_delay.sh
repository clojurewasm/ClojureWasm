#!/usr/bin/env bash
# test/e2e/phase14_future_promise_delay.sh
#
# Phase 14 §9.16 row 14.8 — Tier A concurrent primitives. cw v1's
# single-thread Phase 14 implementation:
# - (delay expr...) — lazy memoised computation; thunk runs on first deref.
# - (future expr...) — eager-at-construction; deref returns the cache.
# - (promise) + (deliver p v) + (deref p) — write-once cell.
#
# The single-thread runtime cannot block on itself, so deref of an
# undelivered promise raises `promise_undelivered_error` instead of
# blocking forever (PROVISIONAL; Phase 15.1 swap to blocking via
# std.Io.Mutex). JVM-style thread spawning for future is also Phase
# 15.1 (D-114).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { tail -n 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- Delay ---
got=$("$BIN" -e '(deref (delay (+ 1 2)))' 2>/dev/null | last_line)
assert_eq 'delay_deref_basic' "$got" '3'

got=$("$BIN" -e '(realized? (delay 99))' 2>/dev/null | last_line)
assert_eq 'delay_unrealised' "$got" 'false'

# Memoisation: a counter-style delay should produce the same value twice.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def d (delay (+ 1 2)))
[(deref d) (deref d) (realized? d)]
EOF
)
assert_eq 'delay_memoised_cached' "$got" '[3 3 true]'

# --- Future ---
got=$("$BIN" -e '(deref (future (* 7 6)))' 2>/dev/null | last_line)
assert_eq 'future_deref_eager' "$got" '42'

# Eager: future body runs at construction, so realized? is true immediately.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def f (future (+ 100 200)))
[(realized? f) (deref f)]
EOF
)
assert_eq 'future_realized_immediately' "$got" '[true 300]'

# --- Promise ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(deliver p 42)
(deref p)
EOF
)
assert_eq 'promise_deliver_then_deref' "$got" '42'

got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
[(realized? p) (do (deliver p :v) (realized? p))]
EOF
)
assert_eq 'promise_realized_transition' "$got" '[false true]'

# Retry-deliver returns nil per JVM semantics; original value preserved.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(deliver p :first)
(let [retry (deliver p :second)]
  [retry (deref p)])
EOF
)
assert_eq 'promise_retry_deliver_nil_preserves' "$got" '[nil :first]'

# --- Promise: undelivered deref raises a PROVISIONAL diagnostic ---
diag=$("$BIN" -e '(deref (promise))' 2>&1 || true)
case "$diag" in
    *"block forever"*|*"undelivered"*|*"not_implemented"*)
        echo "PASS promise_undelivered_raises -> diagnostic" ;;
    *)
        fail "promise_undelivered_raises: expected PROVISIONAL diagnostic, got '$diag'" ;;
esac

echo
echo "Phase 14 row 14.8 future/promise/delay e2e: all green."
