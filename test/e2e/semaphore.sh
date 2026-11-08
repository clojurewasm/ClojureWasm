#!/usr/bin/env bash
# test/e2e/semaphore.sh
#
# ADR-0029 / ADR-0106 — java.util.concurrent.Semaphore as a stateful native
# instance. Permits move by CAS; a timed wait polls through the same
# budgeted sleep Thread/sleep owns. AD-061 pins the fairness divergence.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
run() { "$BIN" -e "$1" 2>/dev/null; }

MS='java.util.concurrent.TimeUnit/MILLISECONDS'

# --- permits: acquire drains, release restores ---
assert_eq 'available_initial' "$(run '(.availablePermits (java.util.concurrent.Semaphore. 3))')" '3'
assert_eq 'tryAcquire_until_empty' \
  "$(run '(let [s (java.util.concurrent.Semaphore. 2)] [(.tryAcquire s) (.tryAcquire s) (.tryAcquire s)])')" \
  '[true true false]'
assert_eq 'release_restores' \
  "$(run '(let [s (java.util.concurrent.Semaphore. 1)] (.tryAcquire s) (.release s) (.availablePermits s))')" '1'
assert_eq 'release_past_initial' \
  "$(run '(let [s (java.util.concurrent.Semaphore. 1)] (.release s 4) (.availablePermits s))')" '5'

# --- multi-permit costs ---
assert_eq 'cost_acquire' \
  "$(run "(let [s (java.util.concurrent.Semaphore. 10)] [(.tryAcquire s 4 50 $MS) (.availablePermits s) (.tryAcquire s 7 50 $MS)])")" \
  '[true 6 false]'
assert_eq 'drainPermits' \
  "$(run '(let [s (java.util.concurrent.Semaphore. 7)] [(.drainPermits s) (.availablePermits s) (.drainPermits s)])')" \
  '[7 0 0]'

# --- timed tryAcquire: a release from another thread wakes the waiter ---
assert_eq 'timed_acquire_after_release' \
  "$(run "(let [s (java.util.concurrent.Semaphore. 1)
                _ (.tryAcquire s)
                f (future (Thread/sleep 80) (.release s))
                got (.tryAcquire s 2000 $MS)]
            @f got)")" \
  'true'

# --- timed tryAcquire: exhausted semaphore returns false at the deadline ---
assert_eq 'timed_acquire_times_out' \
  "$(run "(let [s (java.util.concurrent.Semaphore. 1)
                _ (.tryAcquire s)
                t0 (System/currentTimeMillis)
                got (.tryAcquire s 60 $MS)
                dt (- (System/currentTimeMillis) t0)]
            [got (>= dt 55)])")" \
  '[false true]'

# --- blocking acquire returns once a permit lands ---
assert_eq 'acquire_blocks_then_returns' \
  "$(run '(let [s (java.util.concurrent.Semaphore. 0)
                f (future (Thread/sleep 60) (.release s))]
            (.acquire s) @f (.availablePermits s))')" '0'

# --- getQueueLength counts parked callers only ---
assert_eq 'queue_length_idle' \
  "$(run '(let [s (java.util.concurrent.Semaphore. 1)] [(.getQueueLength s) (.hasQueuedThreads s)])')" \
  '[0 false]'
assert_eq 'queue_length_while_parked' \
  "$(run "(let [s (java.util.concurrent.Semaphore. 1)
                _ (.tryAcquire s)
                f (future (.tryAcquire s 400 $MS))
                _ (Thread/sleep 80)
                queued (.getQueueLength s)]
            (.release s) @f [queued (.getQueueLength s)])")" \
  '[1 0]'

# --- AD-061: fair? is recorded and reported, acquisition still barges ---
assert_eq 'isFair_records_flag' \
  "$(run '[(.isFair (java.util.concurrent.Semaphore. 1 true)) (.isFair (java.util.concurrent.Semaphore. 1))]')" \
  '[true false]'

# --- class / instance identity ---
assert_eq 'class_name' \
  "$(run '(= "java.util.concurrent.Semaphore" (str (class (java.util.concurrent.Semaphore. 1))))')" 'true'

echo "OK test/e2e/semaphore.sh"
