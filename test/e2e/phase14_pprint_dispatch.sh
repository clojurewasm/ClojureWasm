#!/usr/bin/env bash
# test/e2e/phase14_pprint_dispatch.sh — clojure.pprint dispatch surface (D-402).
# cljw's `pprint` was `println` (NOT pr-readable: strings unquoted, diverging from
# clj). Rewired to consult `*print-pprint-dispatch*` (pr-based by default), which
# fixes string quoting AND adds the dispatch system `with-pprint-dispatch` /
# `simple-dispatch` / `code-dispatch` that macro-pretty-printing libs need
# (clojure.tools.logging's `spy`: `(with-pprint-dispatch code-dispatch (pprint …))`).
# cljw has no width-aware / code-specific formatter, so code-dispatch == simple
# (a documented divergence — output is single-line pr, not indented). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

run() { "$BIN" - <<EOF 2>&1 | tail -1
(require '[clojure.pprint :as pp])
$1
EOF
}

# pprint a string is now pr-readable (quoted), matching clj (was unquoted)
assert_eq 'pprint-string-quoted' "$(run '(prn (with-out-str (pp/pprint "hi")))')"   '"\"hi\"\n"'
# pprint a map (short) matches clj
assert_eq 'pprint-map'           "$(run '(prn (with-out-str (pp/pprint {:a 1})))')"  '"{:a 1}\n"'
# pprint still returns nil
assert_eq 'pprint-returns-nil'   "$(run '(prn (pp/pprint [1 2 3]))')"                'nil'
# with-pprint-dispatch + code-dispatch resolve + run (the tools.logging shape)
assert_eq 'with-pprint-dispatch' "$(run '(prn (with-out-str (pp/with-pprint-dispatch pp/code-dispatch (pp/pprint [1 2]))))')" '"[1 2]\n"'
# simple-dispatch resolves
assert_eq 'simple-dispatch'      "$(run '(prn (with-out-str (pp/with-pprint-dispatch pp/simple-dispatch (pp/pprint :k))))')"  '":k\n"'

echo "OK — phase14_pprint_dispatch (5 cases) green"
