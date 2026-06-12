#!/usr/bin/env bash
# test/e2e/phase14_fn_combinators.sh
#
# D-134 missing-core batch — fn combinators: some-fn / every-pred /
# trampoline / replace (Pattern A `.clj` over primitives). These ride the
# AOT-bootstrap blob (ADR-0056): core.clj is build-time bytecode-compiled,
# so a passing run also confirms these new fns AOT-restore faithfully
# (incl. loop/recur in some-fn + multi-arity self-recursive trampoline).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# some-fn — first logical-true (pred result), else the LAST pred's value
# (JVM `(or (p1 x) (p2 x))`: both preds → false here, so false not nil).
assert_eq 'somefn_none'  "$("$BIN" -e '((some-fn even? neg?) 3)')"   'false'
assert_eq 'somefn_first' "$("$BIN" -e '((some-fn even? neg?) 4)')"   'true'
assert_eq 'somefn_later' "$("$BIN" -e '((some-fn even? neg?) -3)')"  'true'
# every-pred — true iff all preds pass
assert_eq 'everyp_all'   "$("$BIN" -e '((every-pred pos? even?) 4)')"  'true'
assert_eq 'everyp_odd'   "$("$BIN" -e '((every-pred pos? even?) 3)')"  'false'
assert_eq 'everyp_neg'   "$("$BIN" -e '((every-pred pos? even?) -4)')" 'false'
# trampoline — bounce until non-fn
assert_eq 'tramp_direct' "$("$BIN" -e '(trampoline (fn* [] 42))')"                      '42'
assert_eq 'tramp_bounce' "$("$BIN" -e '(trampoline (fn* [] (fn* [] (fn* [] 7))))')"     '7'
# replace — vector in → vector out; seq in → realized via vec
assert_eq 'replace_vec'  "$("$BIN" -e '(replace {:a 1 :b 2} [:a :b :c :a])')"   '[1 2 :c 1]'
assert_eq 'replace_seq'  "$("$BIN" -e '(vec (replace {2 :two} (list 1 2 3 2)))')" '[1 :two 3 :two]'

echo "OK — phase14_fn_combinators smoke (10 cases) green"
