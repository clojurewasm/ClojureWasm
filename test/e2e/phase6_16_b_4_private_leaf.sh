#!/usr/bin/env bash
# test/e2e/phase6_16_b_4_private_leaf.sh
#
# Phase 6.16.b-4 sub-cycle a — D-071 Part 3 closeout.
#
# After landing this cycle the 6 `-*-eager` leaves (currently parked
# in `rt/` with `.private = false`) live in `clojure.core/` with
# `.private = true`. core.clj's wrappers (`map`, `filter`, etc.)
# resolve them as same-ns Vars; user-ns callers cannot reach them
# via the `clojure.core/-foo-eager` qualified path.
#
# ADR-0033 D4 + analyzer infra at src/eval/analyzer/analyzer.zig
# L368-382 (cross-ns private check) — this test exercises the user-
# visible end of the chain.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

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

# --- (1) Public wrapper still works from user/ ---
# `map` / `filter` are public clojure.core Vars (now lazy `.clj` per
# ADR-0054). Public access from user/ is unrestricted; the private
# check only bites on qualified access to a `-`-prefixed leaf (2).
got="$("$BIN" -e '(map inc [1 2 3])')"
assert_eq 'public_wrapper_map' "$got" '(2 3 4)'

got="$("$BIN" -e '(filter pos? [-1 0 1 2])')"
assert_eq 'public_wrapper_filter' "$got" '(1 2)'

# --- (2) Direct qualified access to the leaf from user/ is denied ---
# `(clojure.core/-take-eager ...)` resolves the Var across namespaces
# (env.current_ns = user, v_ptr.ns = clojure.core). The analyzer's
# private check at analyzer.zig:374-381 raises private_access_error.
# (`-take-eager` is the SOLE surviving private seq leaf — `-map-eager` /
# `-filter-eager` / `-keep-eager` / `-remove-eager` / `-drop-eager` were
# all deleted as map/filter/keep/remove/drop went lazy, ADR-0054.)
got="$("$BIN" -e '(clojure.core/-take-eager 2 [1 2 3])' 2>&1 || true)"
if ! grep -q 'name_error' <<<"$got"; then
    fail "private_leaf_qualified_kind: missing [name_error] tag (got '$got')"
fi
if ! grep -q "private" <<<"$got"; then
    fail "private_leaf_qualified_template: missing 'private' wording (got '$got')"
fi
if ! grep -q "clojure.core/-take-eager" <<<"$got"; then
    fail "private_leaf_qualified_sym: missing 'clojure.core/-take-eager' (got '$got')"
fi
echo "PASS private_leaf_qualified_user_denied"

# --- (3) Same-ns access inside clojure.core works ---
# Switching into clojure.core and calling unqualified -take-eager
# resolves same-ns (env.current_ns == v_ptr.ns == clojure.core), so
# the private check passes. (in-ns prints its return value 'nil'
# first; assert on the last line.)
got="$("$BIN" -e "(in-ns 'clojure.core) (-take-eager 2 [1 2 3])" | tail -n 1)"
assert_eq 'private_leaf_same_ns' "$got" '(1 2)'

echo ""
echo "=== phase6_16_b_4_private_leaf: all assertions passed ==="
