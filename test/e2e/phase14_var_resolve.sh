#!/usr/bin/env bash
# test/e2e/phase14_var_resolve.sh
#
# Var surface: (def x ..) / (defn ..) return a runtime var_ref Value that
# prints as the var-quote form #'ns/name (not the generic #<var_ref>).
# resolve cases land alongside in a later cycle.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

assert_eq() {
    local name="$1"
    local got="$2"
    local want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

# --- Case 1: (def x 1) prints the var-quote form #'user/x ---
assert_eq 'def_returns_var_quote' "$("$BIN" -e '(def x 1)' 2>/dev/null | tail -1)" "#'user/x"

# --- Case 2: (defn f [] 1) prints #'user/f ---
assert_eq 'defn_returns_var_quote' "$("$BIN" -e '(defn f [] 1)' 2>/dev/null | tail -1)" "#'user/f"

# --- Case 3: (resolve 'sym) returns the var for a user-defined name ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def myv 42)
(prn (resolve 'myv))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'resolve_user_var' "$(tail -1 <<< "$got")" "#'user/myv"

# --- Case 4: (resolve 'undefined) → nil ---
assert_eq 'resolve_unresolvable_nil' "$("$BIN" -e "(resolve 'totally-undefined-xyz)" 2>/dev/null | tail -1)" 'nil'

# --- Case 5: resolve returns a deref-able var ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def myv 42)
(prn (deref (resolve 'myv)))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'resolve_var_deref' "$(tail -1 <<< "$got")" '42'

assert_contains() {
    local name="$1"
    local got="$2"
    local needle="$3"
    case "$got" in
        *"$needle"*) echo "PASS $name -> contains '$needle'" ;;
        *) fail "$name: got '$got', want substring '$needle'" ;;
    esac
}

# --- D-261: a fully-qualified symbol `ns/name` is a direct ns-var lookup that
# bypasses refers/aliases. A var referred-but-not-interned in `ns` does NOT
# satisfy `ns/name` (clj: "No such var: ns/name"). ---

# Case 6: subs is clojure.core, only REFERRED into clojure.string → error.
assert_contains 'qualified_referred_var_errors' \
    "$("$BIN" -e '(clojure.string/subs "hello" 1 3)' 2>&1 || true)" 'Unable to resolve var'

# Case 7: count is core, referred into clojure.set → error.
assert_contains 'qualified_core_via_other_ns_errors' \
    "$("$BIN" -e '(clojure.set/first [1 2])' 2>&1 || true)" 'Unable to resolve var'

# Case 8: upper-case IS interned in clojure.string → still resolves.
assert_eq 'qualified_own_intern_resolves' \
    "$("$BIN" -e '(clojure.string/upper-case "hi")' 2>/dev/null | tail -1)" '"HI"'

# Case 9: clojure.core/map — map is interned in core → still resolves.
assert_eq 'qualified_core_own_intern_resolves' \
    "$("$BIN" -e '(clojure.core/map inc [1 2])' 2>/dev/null | tail -1)" '(2 3)'

# Case 10: clojure.core/subs — subs is an rt-origin var re-exported into
# clojure.core via refers. clj interns ALL core fns in clojure.core, so
# `clojure.core/subs` MUST resolve even though cljw's `subs` physically lives
# in the internal `rt/` ns (the clojure.core-refers-as-own exception, D-261).
assert_eq 'qualified_core_rt_origin_resolves' \
    "$("$BIN" -e '(clojure.core/subs "hello" 1 3)' 2>/dev/null | tail -1)" '"el"'

echo "OK — phase14_var_resolve (10 cases) green"
