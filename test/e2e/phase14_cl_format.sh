#!/usr/bin/env bash
# test/e2e/phase14_cl_format.sh — clojure.pprint/cl-format common subset (D-403).
# A bounded, useful directive set: ~A (aesthetic) / ~S (standard, pr-readable) /
# ~D (decimal) / ~% (newline) / ~~ (literal tilde). `(cl-format nil fmt & args)`
# returns the string; unsupported directives raise explicitly (no silent
# mishandling). The full cl-format DSL (~F float, ~{~} iteration, …) stays
# deferred. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

run() { "$BIN" - <<EOF 2>&1 | tail -1
(require '[clojure.pprint :as pp])
$1
EOF
}

assert_eq 'aesthetic'  "$(run '(prn (pp/cl-format nil "~a + ~a = ~a" 1 2 3))')"  '"1 + 2 = 3"'
assert_eq 'standard'   "$(run '(prn (pp/cl-format nil "~s" "hi"))')"             '"\"hi\""'
assert_eq 'decimal'    "$(run '(prn (pp/cl-format nil "~d items" 42))')"         '"42 items"'
assert_eq 'newline'    "$(run '(prn (pp/cl-format nil "a~%b"))')"                '"a\nb"'
assert_eq 'tilde'      "$(run '(prn (pp/cl-format nil "100~~"))')"               '"100~"'
assert_eq 'aesthetic-string' "$(run '(prn (pp/cl-format nil "[~a]" "x"))')"      '"[x]"'
# unsupported directive raises explicitly (not silent mishandle)
assert_eq 'unsupported-raises' "$(run '(prn (try (pp/cl-format nil "~f" 1.5) (catch Throwable e :raised)))')" ':raised'

echo "OK — phase14_cl_format (7 cases) green"
