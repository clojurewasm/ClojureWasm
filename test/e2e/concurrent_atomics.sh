#!/usr/bin/env bash
# test/e2e/concurrent_atomics.sh
#
# ADR-0029 / ADR-0106 — the value tier under the executor surfaces:
# java.util.concurrent.atomic.{AtomicLong,AtomicInteger,AtomicBoolean},
# java.util.concurrent.TimeoutException, and the java.lang.Runtime memory
# readings. AD-062 pins AtomicInteger's non-truncation; AD-063 pins the
# Runtime memory mapping onto cljw's own GC accounting.

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

AL='java.util.concurrent.atomic.AtomicLong'
AI='java.util.concurrent.atomic.AtomicInteger'
AB='java.util.concurrent.atomic.AtomicBoolean'

# --- AtomicLong: the get/set/add family ---
assert_eq 'atomiclong_default_zero' "$(run "(.get ($AL.))")" '0'
assert_eq 'atomiclong_increment' \
  "$(run "(let [a ($AL. 0)] [(.incrementAndGet a) (.getAndIncrement a) (.get a) (.decrementAndGet a)])")" \
  '[1 1 2 1]'
assert_eq 'atomiclong_add' \
  "$(run "(let [a ($AL. 10)] [(.addAndGet a 5) (.getAndAdd a 5) (.get a)])")" \
  '[15 15 20]'
assert_eq 'atomiclong_set_and_getAndSet' \
  "$(run "(let [a ($AL. 1)] (.set a 9) [(.get a) (.getAndSet a 3) (.get a)])")" \
  '[9 9 3]'

# --- compareAndSet only fires on a matching witness ---
assert_eq 'atomiclong_cas' \
  "$(run "(let [a ($AL. 7)] [(.compareAndSet a 7 9) (.get a) (.compareAndSet a 7 1) (.get a)])")" \
  '[true 9 false 9]'

# --- AD-062: AtomicInteger stores an i64 and does NOT truncate to 32 bits ---
assert_eq 'atomicinteger_no_32bit_truncation' \
  "$(run "(let [a ($AI. 2147483647)] [(.get a) (.incrementAndGet a)])")" \
  '[2147483647 2147483648]'

# --- AtomicBoolean ---
assert_eq 'atomicboolean_cas' \
  "$(run "(let [a ($AB. false)] [(.get a) (.compareAndSet a false true) (.get a) (.getAndSet a false) (.get a)])")" \
  '[false true true true false]'

# --- the counter is atomic under cljw's real OS threads (F-006) ---
assert_eq 'atomiclong_contended_count_is_exact' \
  "$(run "(let [a ($AL. 0)
                fs (doall (for [_ (range 4)] (future (dotimes [_ 500] (.incrementAndGet a)))))]
            (doseq [f fs] @f)
            (.get a))")" \
  '2000'

# --- class identity ---
assert_eq 'atomiclong_class_name' "$(run "(= \"$AL\" (str (class ($AL. 1))))")" 'true'

# --- TimeoutException: constructible, and caught by both spellings ---
assert_eq 'timeout_exception_caught_by_own_class' \
  "$(run '(try (throw (java.util.concurrent.TimeoutException. "late"))
            (catch java.util.concurrent.TimeoutException e (ex-message e)))')" \
  '"late"'
assert_eq 'timeout_exception_is_an_exception' \
  "$(run '(try (throw (java.util.concurrent.TimeoutException. "late"))
            (catch Exception _ :caught-as-exception))')" \
  ':caught-as-exception'

# --- AD-063: Runtime memory answers from cljw's own GC accounting ---
assert_eq 'runtime_memory_is_coherent' \
  "$(run '(let [r (Runtime/getRuntime) t (.totalMemory r) f (.freeMemory r)]
            [(pos? t) (<= 0 f) (<= f t) (integer? t)])')" \
  '[true true true true]'
# An unmetered heap has no ceiling to report, and Long/MAX_VALUE must stay an
# exact Long — `Value.initInteger` would silently hand back a Double past i48.
assert_eq 'runtime_maxmemory_unmetered_is_exact_long' \
  "$(run '(let [m (.maxMemory (Runtime/getRuntime))] [(= m Long/MAX_VALUE) (str (class m))])')" \
  '[true "Long"]'

echo "OK test/e2e/concurrent_atomics.sh"
