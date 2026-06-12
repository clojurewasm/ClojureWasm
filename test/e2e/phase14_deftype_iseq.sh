#!/usr/bin/env bash
# test/e2e/phase14_deftype_iseq.sh — clojure.lang.Sequential + clojure.lang.ISeq
# as deftype host-supertype markers (D-395, the D-271/D-280 family). A custom
# seq deftype (instaparse's AutoFlattenSeq) declares Sequential (zero-method) +
# ISeq (first/next/more/cons + the inherited count/empty/equiv/seq). All targets
# already exist + DISPATCH on typed_instances: first/next/more→ISeq -first/-next/
# -rest (D-280d), cons/count/empty→IPersistentCollection -cons/-count/-empty,
# equiv→Object/equiv, seq→Seqable/-seq — so this is a REAL win, the seq ops
# actually dispatch to the deftype's impls (not load-level-only). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# a deftype wrapping a vector, exposing it as a seq via ISeq + Seqable
DT='(deftype L [v]
  clojure.lang.Sequential
  clojure.lang.Seqable
  (seq [self] (seq v))
  clojure.lang.ISeq
  (first [self] (first v))
  (next [self] (next v))
  (more [self] (rest v))
  clojure.lang.Counted
  (count [self] (count v)))'
run() { "$BIN" - <<EOF 2>&1 | tail -1
$DT
$1
EOF
}

assert_eq 'first-dispatch'  "$(run '(prn (first (L. [10 20 30])))')"      '10'
assert_eq 'seq-dispatch'    "$(run '(prn (seq (L. [4 5 6])))')"           '(4 5 6)'
assert_eq 'count-dispatch'  "$(run '(prn (count (L. [1 2 3 4])))')"       '4'
assert_eq 'sequential-pred' "$(run '(prn (sequential? (L. [1])))')"       'true'
assert_eq 'rest-dispatch'   "$(run '(prn (rest (L. [7 8 9])))')"          '(8 9)'

echo "OK — phase14_deftype_iseq (5 cases) green"
