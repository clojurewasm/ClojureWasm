#!/usr/bin/env bash
# test/e2e/phase15_thread_lifecycle.sh
#
# ADR-0174 D6 — the minimal Thread lifecycle surface (user-authorized
# F-014 exception, 2026-07-16): (Thread. f) / (Thread. f name), .start,
# .join (0-arg + ms), .isAlive, .getName/.setName, .setDaemon/.isDaemon,
# Thread/yield, Thread/onSpinWait, MIN/NORM/MAX_PRIORITY. JVM-faithful
# non-daemon default: main waits for live non-daemon threads at exit
# (the join-at-exit registry), so `(.start (Thread. f))` completes f
# where a silently-detached thread would truncate it. The interrupt
# family is deliberately absent (a flag-only interrupt that cannot wake
# a sleeping thread would be a semantic lie) — D3 diagnostics + debt row.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> ${want//$'\n'/\\n}"
}

# `|| true`: the error-path cases (double start, setDaemon after start)
# exit non-zero by design; without it `set -e` kills the script at the
# command substitution.
run() { "$BIN" - <<EOF 2>&1 || true
$1
EOF
}

# --- the user's original repro: ctor + start (+ join for determinism) ---
assert_eq 'ctor_start_join' "$(run '(let [t (Thread. (fn [] (println "Hello from thread")))]
  (.start t)
  (.join t))')" 'Hello from thread'

# --- non-daemon default: main exit WAITS for the thread (join-at-exit) ---
assert_eq 'nondaemon_join_at_exit' "$(run '(.start (Thread. (fn [] (Thread/sleep 80) (println "late-but-printed"))))')" 'late-but-printed'

# --- daemon: main exit does NOT wait (output absent, process exits fast) ---
start_ns=$(date +%s)
got=$(run '(let [t (Thread. (fn [] (Thread/sleep 5000) (println "never")))]
  (.setDaemon t true)
  (.start t)
  (println "main-done"))')
end_ns=$(date +%s)
[[ "$got" == "main-done" ]] || fail "daemon_no_wait: got '$got'"
(( end_ns - start_ns < 4 )) || fail "daemon_no_wait: took $((end_ns - start_ns))s (waited for daemon?)"
echo "PASS daemon_no_wait"

# --- names: auto Thread-N, explicit ctor name, setName ---
assert_eq 'auto_name' "$(run '(println (boolean (re-find #"^Thread-\d+$" (.getName (Thread. (fn []))))))')" 'true'
assert_eq 'ctor_name' "$(run '(println (.getName (Thread. (fn []) "worker-1")))')" 'worker-1'
assert_eq 'set_name'  "$(run '(let [t (Thread. (fn []))]
  (.setName t "renamed")
  (println (.getName t)))')" 'renamed'

# --- currentThread inside the thread is THAT thread (not main) ---
assert_eq 'current_thread_inside' "$(run '(let [t (Thread. (fn [] (println (.getName (Thread/currentThread)))) "inner")]
  (.start t)
  (.join t))')" 'inner'
assert_eq 'main_thread_name' "$(run '(println (.getName (Thread/currentThread)))')" 'main'

# --- isAlive lifecycle ---
assert_eq 'is_alive' "$(run '(let [t (Thread. (fn [] (Thread/sleep 100)))]
  (println (.isAlive t))
  (.start t)
  (println (.isAlive t))
  (.join t)
  (println (.isAlive t)))')" $'false\ntrue\nfalse'

# --- second start is an error (JVM IllegalThreadStateException) ---
got=$(run '(let [t (Thread. (fn []))]
  (.start t)
  (.join t)
  (.start t))')
[[ "$got" == *"already started"* ]] || fail "double_start: got '$got'"
echo "PASS double_start"

# --- timed join returns after the timeout while the thread still runs ---
assert_eq 'timed_join' "$(run '(let [t (Thread. (fn [] (Thread/sleep 300)) "slow")]
  (.start t)
  (.join t 30)
  (println (.isAlive t))
  (.join t)
  (println (.isAlive t)))')" $'true\nfalse'

# --- daemon flag: read-back + post-start setDaemon is an error ---
assert_eq 'daemon_flag' "$(run '(let [t (Thread. (fn []))]
  (println (.isDaemon t))
  (.setDaemon t true)
  (println (.isDaemon t)))')" $'false\ntrue'
got=$(run '(let [t (Thread. (fn [] (Thread/sleep 50)))]
  (.start t)
  (.setDaemon t true))')
[[ "$got" == *"already started"* ]] || fail "setdaemon_after_start: got '$got'"
echo "PASS setdaemon_after_start"

# --- statics: yield / onSpinWait / priority constants ---
assert_eq 'yield_spin' "$(run '(println [(Thread/yield) (Thread/onSpinWait)])')" '[nil nil]'
assert_eq 'priorities' "$(run '(println [Thread/MIN_PRIORITY Thread/NORM_PRIORITY Thread/MAX_PRIORITY])')" '[1 5 10]'

# --- class identity on the merged descriptor ---
assert_eq 'thread_class' "$(run '(println (str (class (Thread. (fn [])))))')" 'java.lang.Thread'
assert_eq 'thread_instance' "$(run '(println (instance? Thread (Thread. (fn []))))')" 'true'

echo "ALL PASS"
