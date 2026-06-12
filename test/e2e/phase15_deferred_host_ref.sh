#!/usr/bin/env bash
# test/e2e/phase15_deferred_host_ref.sh — ADR-0113 / AD-022. An unresolved
# `clojure.lang.*` / `clojure.asm.*` reference defers to a CALL-time
# feature_not_supported instead of failing the whole namespace at analysis, so a
# fn whose body names such a JVM-internal class DEFINES + LOADS; the ref errors
# only if evaluated. A user alias typo stays a LOUD analysis error (strict prefix
# allowlist). Surfaced by integrant's `(clojure.lang.RT/baseLoader)`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { printf '%s' "$1" | tail -1; }

# defines_and_loads: a fn body naming clojure.lang.RT defines; the do returns :ok
got="$("$BIN" -e '(do (defn f [] (clojure.lang.RT/baseLoader)) :ok)' 2>&1 || true)"
[[ "$(last_line "$got")" == ':ok' ]] || fail "defines_and_loads: got '$(last_line "$got")'"
echo "PASS defines_and_loads -> :ok"

# raises_when_called: invoking the unsupported ref errors loudly at call time
got2="$("$BIN" -e '(do (defn f [] (clojure.lang.RT/baseLoader)) (f))' 2>&1 || true)"
printf '%s' "$got2" | grep -q 'clojure.lang.RT/baseLoader is not supported' || fail "raises_when_called: got '$got2'"
echo "PASS raises_when_called -> feature_not_supported"

# value-position (a static field read) defers identically
got3="$("$BIN" -e '(do (def g (fn [] clojure.lang.Compiler/CHAR_MAP)) :defined)' 2>&1 || true)"
[[ "$(last_line "$got3")" == ':defined' ]] || fail "value_position_defines: got '$(last_line "$got3")'"
echo "PASS value_position_defines -> :defined"

# typo_stays_loud: a non-clojure.lang.* unresolved ns is STILL a loud error
got4="$("$BIN" -e '(myalias/foo 1)' 2>&1 || true)"
printf '%s' "$got4" | grep -q "No namespace: 'myalias'" || fail "typo_stays_loud: got '$got4'"
echo "PASS typo_stays_loud -> No namespace: 'myalias'"

echo "OK — phase15_deferred_host_ref (4 cases) green"
