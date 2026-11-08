#!/usr/bin/env bash
# test/e2e/phase15_thread_lifecycle.sh — ADR-0174 D6, the process-exit half of
# the Thread lifecycle. JVM-faithful non-daemon default: main waits for live
# non-daemon threads at exit (the join-at-exit registry), so
# `(.start (Thread. f))` completes f; a daemon thread does NOT hold the process.
# Both are statements about when the PROCESS ends, so they need one. The
# in-process lifecycle (ctor/start/join, names, isAlive, double start,
# timed join, daemon flag, statics, class) lives in
# test/clj/suites/concurrency_host_test.clj (p15-thread-lifecycle).
# e2e-process-boundary: join-at-exit and daemon-no-wait are observable only as process exit behaviour
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
run() { "$BIN" - <<EOF 2>&1 || true
$1
EOF
}

# non-daemon default: main exit WAITS for the thread (join-at-exit)
got=$(run '(.start (Thread. (fn [] (Thread/sleep 80) (println "late-but-printed"))))')
[[ "$got" == "late-but-printed" ]] || fail "nondaemon_join_at_exit: got '$got'"
echo "PASS nondaemon_join_at_exit"

# daemon: main exit does NOT wait (output absent, process exits fast)
start_s=$(date +%s)
got=$(run '(let [t (Thread. (fn [] (Thread/sleep 5000) (println "never")))]
  (.setDaemon t true)
  (.start t)
  (println "main-done"))')
end_s=$(date +%s)
[[ "$got" == "main-done" ]] || fail "daemon_no_wait: got '$got'"
(( end_s - start_s < 4 )) || fail "daemon_no_wait: took $((end_s - start_s))s (waited for daemon?)"
echo "PASS daemon_no_wait"

echo "OK — phase15_thread_lifecycle (2 process cases) green"
