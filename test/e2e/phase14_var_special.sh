#!/usr/bin/env bash
# test/e2e/phase14_var_special.sh
#
# D-183 part (a): the `var` special form + the `#'` reader macro.
# `(var x)` / `#'x` resolve the symbol to its Var and yield a `.var_ref`
# Value that prints `#'ns/name` and derefs (via `deref`/`@`) to the Var's
# value. Mirrors `'`→(quote ..) and `@`→(deref ..). The Var reference
# Value type (tag 20) + `__resolve` + printVarRef already exist; this
# cycle wires the surface (reader + special form).
#
# `cljw -e` prints the last form's value, so each case asserts the LAST
# line.
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

# --- (var x) special form: resolves to the Var, prints #'ns/name ---
assert_last 'var_special'   '(def x 5) (var x)'        "#'user/x"
# --- #'x reader macro → (var x) ---
assert_last 'var_reader'    '(def x 5) #'"'"'x'          "#'user/x"
# --- deref a var_ref → the Var's value ---
assert_last 'var_deref'     '(def x 5) (deref (var x))' '5'
assert_last 'var_deref_at'  '(def x 5) @#'"'"'x'         '5'

# --- var-as-IFn (D-231): a var_ref Value in call position derefs to its
#     value and invokes it — the (#'f args) / ((resolve 'f) args) pattern
#     reliable nREPL/cider eval depends on. clj: a Var implements IFn. ---
assert_last 'var_ifn_special'  '((var inc) 5)'                        '6'
assert_last 'var_ifn_resolve'  '((resolve (quote inc)) 5)'           '6'
assert_last 'var_ifn_apply'    '(apply (var +) [1 2 3])'             '6'
assert_last 'var_ifn_hof'      '((resolve (quote map)) inc [1 2 3])' '(2 3 4)'

# `@x` reader is NS-qualified so a local `deref` binding cannot capture it
# (reader hygiene). cljw qualifies to the `rt` primitive ns (AD-038; clj uses
# clojure.core/deref — same hygiene, cljw's canonical core ns is `rt`).
assert_last 'deref_reader_qualified' '(read-string "@deref")'      '(rt/deref deref)'
assert_last 'deref_no_local_capture' '(let [deref (fn [_] :shadowed)] @(atom 5))' '5'

echo "ALL phase14_var_special PASS"
