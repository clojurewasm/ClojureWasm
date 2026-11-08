#!/usr/bin/env bash
# test/e2e/concurrent_interfaces.sh
#
# ADR-0102 / F-013 — the java.util.concurrent functional interfaces a
# concurrency library REIFIES: ThreadFactory, Callable, Runnable.
#
# These are host-interface MARKER names (data/host_interfaces.yaml), not native
# TypeDescriptors, because reify accepts only a protocol Var or a quote-wrapped
# marker — a class value fails with "expected protocol, got type_descriptor".
# Both the bare (post-:import) and fully-qualified spellings must work.

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
# `-e` prints EVERY top-level form's value, and an `(ns …)` form evaluates to
# nil — so a snippet that must set up an :import compares its last line only.
run_last() { "$BIN" -e "$1" 2>/dev/null | tail -1; }

# --- qualified spelling reifies and dispatches ---
assert_eq 'threadfactory_qualified' \
  "$(run '(let [tf (reify java.util.concurrent.ThreadFactory (newThread [_ r] [:made r]))]
            (.newThread tf :work))')" \
  '[:made :work]'
assert_eq 'callable_qualified' \
  "$(run '(.call (reify java.util.concurrent.Callable (call [_] 42)))')" '42'
assert_eq 'runnable_qualified' \
  "$(run '(.run (reify java.lang.Runnable (run [_] :ran)))')" ':ran'

# --- bare spelling after :import reifies and dispatches ---
assert_eq 'threadfactory_bare_after_import' \
  "$(run_last '(ns t1 (:import [java.util.concurrent ThreadFactory]))
          (.newThread (reify ThreadFactory (newThread [_ r] [:bare r])) :w)')" \
  '[:bare :w]'
assert_eq 'callable_bare_after_import' \
  "$(run_last '(ns t2 (:import [java.util.concurrent Callable]))
          (.call (reify Callable (call [_] :bare-call)))')" \
  ':bare-call'
assert_eq 'runnable_bare' \
  "$(run '(.run (reify Runnable (run [_] :bare-run)))')" ':bare-run'

# --- the real shape: a factory that mints a named daemon Thread which runs ---
assert_eq 'threadfactory_mints_a_running_named_daemon_thread' \
  "$(run_last '(ns t3 (:import [java.util.concurrent ThreadFactory]))
          (let [n  (java.util.concurrent.atomic.AtomicLong. 0)
                ok (java.util.concurrent.atomic.AtomicBoolean. false)
                tf (reify ThreadFactory
                     (newThread [_ r]
                       (doto (Thread. r)
                         (.setName (str "wk-" (.incrementAndGet n)))
                         (.setDaemon true))))
                t  (.newThread tf (fn [] (.set ok true)))]
            (.start t)
            (.join t)
            [(.getName t) (.isDaemon t) (.get ok) (.get n)])')" \
  '["wk-1" true true 1]'

# --- a reify may combine one of these with a plain protocol section ---
assert_eq 'threadfactory_alongside_a_protocol' \
  "$(run_last '(ns t4 (:import [java.util.concurrent ThreadFactory]))
          (defprotocol Named (nm [_]))
          (let [o (reify
                    ThreadFactory (newThread [_ r] [:t r])
                    Named         (nm [_] :named))]
            [(.newThread o 1) (nm o)])')" \
  '[[:t 1] :named]'

echo "OK test/e2e/concurrent_interfaces.sh"
