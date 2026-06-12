#!/usr/bin/env bash
# test/e2e/phase15_alias.sh — `alias` / `ns-aliases` (D-232, ns-libs.clj).
# `(alias a ns)` adds a → (the-ns ns) to the current ns; `ns-aliases` reports
# the alias map. clj-equivalence is environmental (clj must `require` the target
# first; cljw bootstraps clojure.* ), so this is a cljw behavioral check. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'alias-use'   "$("$BIN" -e '(alias (quote str) (quote clojure.string)) (str/upper-case "hi")' 2>&1 | tail -1)" '"HI"'
assert_eq 'ns-aliases'  "$("$BIN" -e '(do (alias (quote s) (quote clojure.set)) (contains? (ns-aliases *ns*) (quote s)))' 2>&1 | tail -1)" 'true'
assert_eq 'alias-target' "$("$BIN" -e '(do (alias (quote w) (quote clojure.walk)) (ns-name ((ns-aliases *ns*) (quote w))))' 2>&1 | tail -1)" 'clojure.walk'
assert_eq 'alias-unknown' "$("$BIN" -e '(alias (quote x) (quote no.such.ns))' 2>&1 | grep -cm1 'Could not locate')" '1'

echo "OK — phase15_alias (4 cases) green"
