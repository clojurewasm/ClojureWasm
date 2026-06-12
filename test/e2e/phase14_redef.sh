#!/usr/bin/env bash
# test/e2e/phase14_redef.sh
#
# ADR-0038 amendment (D-184): `analyzeDef` declares the def target if absent
# but no longer RESETS an existing Var's root to nil at analyze time. The
# Var still resolves for recursive/forward refs (pre-registration), but a
# re-`def` whose value-expr throws now leaves the old value intact (JVM
# parity), and `defmulti` re-eval is a defonce-style no-op (phase7_multimethod
# case 6). `cljw -e` prints each top-level form, so cases assert the LAST line.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { printf '%s' "$1" | tail -1; }
assert_last() {
    local name="$1"; local expr="$2"; local want="$3"
    local got; got="$(last_line "$("$BIN" -e "$expr" 2>/dev/null)")"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# A re-def whose value-expr THROWS leaves the prior root intact (clj: 5).
assert_last 'redef_throw_keeps' '(def x 5) (try (def x (/ 1 0)) (catch Exception e nil)) x' '5'
# A clean re-def overwrites (no regression).
assert_last 'redef_plain'       '(def y 5) (def y 6) y'                                    '6'
# Pre-registration still resolves recursive / forward refs (regression guard).
assert_last 'recursive_defn'    '(defn f [n] (if (= n 0) 0 (f (dec n)))) (f 5)'           '0'
assert_last 'forward_ref'       '(do (def a 1) (def b a) b)'                              '1'

echo "ALL phase14_redef PASS"
