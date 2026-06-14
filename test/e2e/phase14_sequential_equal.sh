#!/usr/bin/env bash
# test/e2e/phase14_sequential_equal.sh — D-427: `=` compares a deftype/reify that
# declares clojure.lang.Sequential element-wise against any other sequential
# (list/vector/seq), matching clj's Util.pcequiv — NOT by the instance's own
# (often stub) equiv. Formerly cljw's isSequential was a hardcoded tag list that
# excluded typed_instance, so `(= '(1 2) seq-deftype)` was false.
#
# Asserts the clj-VALID subset (list/vector on the LEFT — clj walks via the
# native operand's equiv even when the deftype omits equiv; identity; the
# Sequential gate). Instance-on-LEFT symmetry (which needs the deftype's own
# equiv) is proven against the real lib by verified_projects/data.finger-tree.
# Oracle-confirmed: true/true/true/false/false/false.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

got=$("$BIN" - <<'EOF' 2>/dev/null
;; L is Sequential (compares element-wise); NS is ISeq but NOT Sequential.
(deftype L [x nxt]
  clojure.lang.Seqable (seq [this] this)
  clojure.lang.Sequential
  clojure.lang.ISeq (first [_] x) (more [_] (or nxt ())) (next [_] nxt))
(deftype NS [x]
  clojure.lang.Seqable (seq [this] this)
  clojure.lang.ISeq (first [_] x) (more [_] ()) (next [_] nil))
(def two (L. 1 (L. 2 nil)))
(prn (= '(1 2) two))                  ; true — list = Sequential deftype
(prn (= [1 2] two))                   ; true — vector = Sequential deftype
(prn (= two two))                     ; true — identity
(prn (= '(1 2) (L. 1 (L. 3 nil))))    ; false — content differs
(prn (= '(1 2 3) two))                ; false — length differs
(prn (= '(7) (NS. 7)))                ; false — NS is not Sequential
EOF
) || fail "seq_equal: non-zero exit ($got)"
assert_eq 'list_eq_seqtype'   "$(sed -n '1p' <<< "$got")" 'true'
assert_eq 'vec_eq_seqtype'    "$(sed -n '2p' <<< "$got")" 'true'
assert_eq 'identity'          "$(sed -n '3p' <<< "$got")" 'true'
assert_eq 'content_differs'   "$(sed -n '4p' <<< "$got")" 'false'
assert_eq 'length_differs'    "$(sed -n '5p' <<< "$got")" 'false'
assert_eq 'non_sequential'    "$(sed -n '6p' <<< "$got")" 'false'

echo "OK — phase14_sequential_equal (6 cases) green"
