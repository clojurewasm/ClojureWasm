#!/usr/bin/env bash
# test/e2e/phase15_watch_recursion.sh — ADR-0157 / D-485, the crash half. A
# self-triggering watch / validator used to recurse in native Zig frames until
# the NATIVE stack overflowed (SIGSEGV, exit 139). The guard turns that into a
# catchable StackOverflowError; the catch semantics, legit chains and bounded
# recursion are in-process and live in
# test/clj/suites/concurrency_host_test.clj (p15-watch-recursion). What stays
# here is the assertion that an UNCAUGHT runaway does not kill the process by
# signal, which only an exit code can show.
# e2e-process-boundary: asserts the uncaught native-stack runaway exits cleanly instead of by SIGSEGV (exit 139)
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

WREC='(let [a (atom 0)] (add-watch a :w (fn [k r o n] (swap! r inc))) (swap! a inc))'
set +e
out="$("$BIN" -e "$WREC" 2>&1)"; rc=$?
set -e
[[ "$out" == *"Stack overflow"* ]] || fail "watch_recursion_graceful: '$out' lacks 'Stack overflow'"
[[ "$rc" != 139 ]] || fail "watch_recursion_segfault: exited 139 (SIGSEGV)"
echo "PASS watch_recursion_no_segfault (exit=$rc)"

VREC='(let [a (atom 0)] (set-validator! a (fn [n] (swap! a inc) true)) (reset! a 5))'
rc=$("$BIN" -e "$VREC" >/dev/null 2>&1; echo $?)
[[ "$rc" != 139 ]] || fail "validator_reentry_segfault: exited 139 (SIGSEGV)"
echo "PASS validator_reentry_no_segfault (exit=$rc)"

echo "OK — phase15_watch_recursion (2 process cases) green"
