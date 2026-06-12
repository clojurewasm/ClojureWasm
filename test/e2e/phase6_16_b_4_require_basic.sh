#!/usr/bin/env bash
# test/e2e/phase6_16_b_4_require_basic.sh
#
# Phase 6.16.b-4 sub-cycle c.4 — `require` special form (bare-symbol
# shape). ADR-0035 D2 / D5 / D8.
#
# Coverage at c.4:
#   - `(require 'foo)` on an already-loaded namespace: no-op, returns
#     nil. All 4 bootstrap namespaces (clojure.core / clojure.set /
#     clojure.string / clojure.walk) are loaded at boot, so this
#     exercises the "already loaded" path.
#   - `(require 'no.such.ns)`: resolver returns null → `lib_not_found`
#     catalog Code raise with `name_error` kind.
#   - libspec opts (`:as` / `:refer` / `:reload`) and not-yet-loaded
#     namespace source loading are deferred to sub-cycle c.5.

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

# --- (1) already-loaded bootstrap namespaces: no-op returns nil ---
got="$("$BIN" -e "(require 'clojure.set)")"
assert_eq 'require_clojure_set_noop' "$got" 'nil'

got="$("$BIN" -e "(require 'clojure.string)")"
assert_eq 'require_clojure_string_noop' "$got" 'nil'

got="$("$BIN" -e "(require 'clojure.walk)")"
assert_eq 'require_clojure_walk_noop' "$got" 'nil'

got="$("$BIN" -e "(require 'clojure.core)")"
assert_eq 'require_clojure_core_noop' "$got" 'nil'

# --- (2) public Vars from a require'd ns still resolve through refers ---
# Sanity check: the bootstrap end-of-loadCore fan-out makes
# clojure.set/union reachable as cs/union via `clojure.set/` prefix.
got="$("$BIN" -e "(require 'clojure.set) (clojure.set/union #{1} #{2})")"
# Set element order is hash-determined, accept any 2-element rendering.
case "$got" in
    "nil"$'\n'"#{1 2}"|"nil"$'\n'"#{2 1}")
        echo "PASS require_then_qualified_use -> ${got//$'\n'/\\n}" ;;
    *)
        fail "require_then_qualified_use: unexpected '$got'" ;;
esac

# --- (3) unknown namespace → lib_not_found ---
got="$("$BIN" -e "(require 'no.such.ns)" 2>&1 || true)"
if ! grep -q 'Name error' <<<"$got"; then
    fail "require_unknown_kind: missing [name_error] tag (got '$got')"
fi
if ! grep -q "Could not locate" <<<"$got"; then
    fail "require_unknown_template: missing 'Could not locate' wording (got '$got')"
fi
if ! grep -q "no.such.ns" <<<"$got"; then
    fail "require_unknown_ns: missing 'no.such.ns' (got '$got')"
fi
echo "PASS require_unknown_raises_lib_not_found"

# --- (4) `require` is BOTH a compile-time special form (literal head form)
# AND a runtime Var (ADR-0085: computed/non-head libspecs route to the Var,
# clj parity where require is a function). `(var require)` resolves to the Var. ---
got="$("$BIN" -e "(var require)" 2>&1 || true)"
if ! grep -q "require" <<<"$got" || grep -q 'Name error' <<<"$got"; then
    fail "require_var_ref: expected the require Var, got '$got'"
fi
echo "PASS require_resolves_as_var (ADR-0085)"

echo ""
echo "=== phase6_16_b_4_require_basic: all assertions passed ==="
