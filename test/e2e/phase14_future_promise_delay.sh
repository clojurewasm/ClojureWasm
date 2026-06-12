#!/usr/bin/env bash
# test/e2e/phase14_future_promise_delay.sh
#
# Phase 14 §9.16 row 14.8 — Tier A concurrent primitives.
# - (delay expr...) — lazy memoised computation; thunk runs on first deref.
# - (future expr...) — **Phase B #4b: spawns a REAL OS thread**; (deref f)
#   BLOCKS on an Io.Mutex/Condition cell until the worker realises the Future.
#   `realized?` right after construction is async-racy (the worker may not have
#   finished), so this suite only asserts it AFTER a deref (deterministically true).
# - (promise) + (deliver p v) + (deref p) — write-once cell; (deref p) BLOCKS
#   until delivered (Phase B #4b / D-113), so a cross-thread deliver pattern
#   `(let [p (promise)] (future (deliver p v)) (deref p))` works. A
#   never-delivered deref blocks forever, exactly as JVM Clojure does.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

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
(prn [(deref d) (deref d) (realized? d)])
EOF
)
assert_eq 'delay_memoised_cached' "$got" '[3 3 true]'

# Thread-safe once-semantics (Phase B #4b): a concurrent deref from a future
# thread + the main thread runs the side-effecting thunk EXACTLY once (the
# realise lock serialises; the loser reads the cache).
got=$("$BIN" -e '(let [n (atom 0) d (delay (swap! n inc))] (future (deref d)) (deref d) @n)' 2>/dev/null | last_line)
assert_eq 'delay_once_under_concurrency' "$got" '1'

# --- Future (real OS thread, Phase B #4b) ---
got=$("$BIN" -e '(deref (future (* 7 6)))' 2>/dev/null | last_line)
assert_eq 'future_deref_blocks_for_result' "$got" '42'

# realized? is deterministically true AFTER a deref (the worker has finished).
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def f (future (+ 100 200)))
(deref f)
(prn [(realized? f) (deref f)])
EOF
)
assert_eq 'future_realized_after_deref' "$got" '[true 300]'

# Shared mutable identity across the worker thread: the future mutates the SAME
# atom the main thread reads (not a copy) — the load-bearing concurrency contract.
got=$("$BIN" -e '(let [a (atom 0)] @(future (swap! a inc)) @a)' 2>/dev/null | last_line)
assert_eq 'future_shared_atom_identity' "$got" '1'

# The worker allocates on the shared GC heap (a vector + range) and returns it.
got=$("$BIN" -e '(deref (future (vec (range 5))))' 2>/dev/null | last_line)
assert_eq 'future_worker_allocates' "$got" '[0 1 2 3 4]'

# --- Promise ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(deliver p 42)
(prn (deref p))
EOF
)
assert_eq 'promise_deliver_then_deref' "$got" '42'

got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(prn [(realized? p) (do (deliver p :v) (realized? p))])
EOF
)
assert_eq 'promise_realized_transition' "$got" '[false true]'

# Retry-deliver returns nil per JVM semantics; original value preserved.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(deliver p :first)
(prn (let [retry (deliver p :second)]
  [retry (deref p)]))
EOF
)
assert_eq 'promise_retry_deliver_nil_preserves' "$got" '[nil :first]'

# --- Promise: deref BLOCKS until delivered from another thread (Phase B #4b) ---
got=$("$BIN" -e '(let [p (promise)] (future (deliver p 42)) (deref p))' 2>/dev/null | last_line)
assert_eq 'promise_blocks_until_delivered' "$got" '42'

# Predicates (Phase B): future? / future-done? (the latter after a deref so it is
# deterministically realised).
got=$("$BIN" -e '[(future? (future 1)) (future? 5)]' 2>/dev/null | last_line)
assert_eq 'future_predicate' "$got" '[true false]'
got=$("$BIN" -e '(let [f (future 1)] @f (future-done? f))' 2>/dev/null | last_line)
assert_eq 'future_done_after_deref' "$got" 'true'

echo
echo "Phase 14 row 14.8 future/promise/delay e2e: all green."
