#!/usr/bin/env bash
# test/e2e/phase16_locking.sh
#
# Phase B #6 — `(locking obj body...)`: hold obj's heap-value monitor (ADR-0009
# lock_state bits + a threadlocal reentrancy held-set, runtime/concurrency/
# object_monitor.zig — NOT a JVM monitor) for the body, release on exit. The
# surface primitive is `__locking` (lang/primitive/locking.zig); the macro is
# `expandLocking` (lang/macro_transforms.zig).
#
# Also the AD-014 pin: `(locking <immediate>)` errors (immediates have no
# identity to lock — derives_from F-004), where JVM clj would lock the box.

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

# Single-thread: acquire, run the body, release; the body value is returned.
got=$("$BIN" -e '(locking (atom 0) 42)' 2>/dev/null | last_line)
assert_eq 'locking_basic' "$got" '42'

# Reentrant: the same thread re-acquires the same object WITHOUT deadlock
# (the threadlocal held-set bumps a depth instead of re-CASing the header).
got=$("$BIN" -e '(let [a (atom 0)] (locking a (locking a 99)))' 2>/dev/null | last_line)
assert_eq 'locking_reentrant' "$got" '99'

# The body thunk closes over the surrounding lexical env.
got=$("$BIN" -e '(let [a (atom 5) x 10] (locking a (+ x @a)))' 2>/dev/null | last_line)
assert_eq 'locking_body_env' "$got" '15'

# Mutual exclusion under contention. (reset! a (inc @a)) is a NON-atomic
# read-then-write: without the lock, two threads can read the same @a and both
# write the same value (a lost update), so the total would be < 400. With
# locking serialising the critical section, every increment lands -> exactly 400.
got=$("$BIN" -e '(let [a (atom 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (locking a (reset! a (inc @a)))))) (range 4))) @a)' 2>/dev/null | last_line)
assert_eq 'locking_mutual_exclusion' "$got" '400'

# AD-014 pin: locking an immediate (no HeapHeader, hence no identity) is a clean
# error, not a crash. JVM clj locks the boxed value; cljw errors (derives_from
# F-004). If this ever starts succeeding, AD-014 must be reconsidered.
diag=$("$BIN" -e '(locking 5 42)' 2>&1 || true)
case "$diag" in
    *"requires an object"*|*"identity"*)
        echo "PASS locking_immediate_errors -> diagnostic" ;;
    *)
        fail "locking_immediate_errors: expected an object-identity diagnostic, got '$diag'" ;;
esac

# Missing body is a macroexpand-time error.
diag=$("$BIN" -e '(locking (atom 0))' 2>&1 || true)
case "$diag" in
    *"locking requires"*|*"body form"*)
        echo "PASS locking_no_body_errors -> diagnostic" ;;
    *)
        fail "locking_no_body_errors: expected a 'requires a body' diagnostic, got '$diag'" ;;
esac

# The monitor is released even when the body throws (the primitive's defer): a
# subsequent (locking o ...) on the same object must not deadlock.
got=$("$BIN" -e '(let [o (atom 0)] (try (locking o (throw (ex-info "x" {}))) (catch Throwable e :c)) (locking o 99))' 2>/dev/null | last_line)
assert_eq 'locking_releases_on_throw' "$got" '99'

echo
echo "Phase B #6 locking e2e: all green."
