#!/usr/bin/env bash
# test/e2e/phase15_require_fs.sh — filesystem `require` (D-158, ADR-0084).
# `-cp <dir>` / $CLJW_PATH let `require` load a lib's `.clj` source off disk;
# embedded nses (clojure.core/test) win the chain; cycles raise; missing libs
# raise lib_not_found. The capstone: a disk test-ns requiring clojure.test +
# another disk lib and running its deftest suite. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
CP="test/e2e/fixtures/cljwlib"
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# load a disk lib via -cp + alias
assert_eq 'cp-load'  "$("$BIN" -cp "$CP" -e '(require (quote [demo.math :as m])) (m/square 7)' 2>&1 | tail -1)" '49'
# CLJW_PATH env path
assert_eq 'env-path' "$(CLJW_PATH="$CP" "$BIN" -e '(require (quote [demo.math :as m])) (m/cube 4)' 2>&1 | tail -1)" '64'
# capstone: a disk test-ns (requires clojure.test + demo.math) + run its suite
assert_eq 'run-suite' "$("$BIN" -cp "$CP" -e '(require (quote demo.math-test)) (let [s (clojure.test/run-tests (quote demo.math-test))] [(:pass s) (:fail s)])' 2>&1 | tail -1)" '[4 0]'
# missing lib -> lib_not_found
assert_eq 'missing'  "$("$BIN" -cp "$CP" -e '(require (quote no.such.lib))' 2>&1 | grep -c 'Could not locate')" '1'
# embedded clojure.string NOT shadowed by a stray on-disk file
SHADOW="$(mktemp -d)"; mkdir -p "$SHADOW/clojure"; printf '(ns clojure.string) (def upper-case :HIJACKED)\n' > "$SHADOW/clojure/string.clj"
assert_eq 'no-shadow' "$("$BIN" -cp "$SHADOW" -e '(clojure.string/upper-case "hi")' 2>&1 | tail -1)" '"HI"'
rm -rf "$SHADOW"
# cycle a->b->a -> Cyclic load dependency
CYC="$(mktemp -d)"; mkdir -p "$CYC/cyc"
printf '(ns cyc.a (:require [cyc.b]))\n' > "$CYC/cyc/a.clj"
printf '(ns cyc.b (:require [cyc.a]))\n' > "$CYC/cyc/b.clj"
assert_eq 'cycle' "$("$BIN" -cp "$CYC" -e '(require (quote cyc.a))' 2>&1 | grep -c 'Cyclic load dependency')" '1'
rm -rf "$CYC"

echo "OK — phase15_require_fs (6 cases) green"
