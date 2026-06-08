#!/usr/bin/env bash
# test/e2e/phase6_16_b_4_require_libspec.sh
#
# Phase 6.16.b-4 sub-cycle c.5 — `require` vector libspec
# (`:as` + `:refer`). ADR-0035 D2 / D3 / D4.
#
# Coverage at c.5:
#   - `(require '[ns :as alias])` registers an alias accessible via
#     `alias/name` qualified resolution (analyzer alias-aware path).
#   - `(require '[ns :refer [a b]])` installs explicit per-name
#     refers so the symbols resolve unqualified.
#   - `(require '[ns :refer [private-name]])` raises
#     `private_access_error` (fail-fast per ADR-0035 D4 explicit-refer
#     policy).
#   - `(require '[ns :refer [missing]])` raises `symbol_unresolved`.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

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

# --- (1) :as installs an alias ---
# `(require '[clojure.set :as cs])` then `(cs/union ...)` resolves
# via the alias table (alias takes precedence over literal ns name).
got="$("$BIN" -e "(require '[clojure.set :as cs]) (cs/union #{1} #{2})" | tail -n 1)"
case "$got" in
    "#{1 2}"|"#{2 1}") echo "PASS as_alias_union -> $got" ;;
    *) fail "as_alias_union: unexpected '$got'" ;;
esac

# Alias resolves on a fresh symbol prefix.
got="$("$BIN" -e "(require '[clojure.string :as s]) (s/upper-case \"hi\")" | tail -n 1)"
assert_eq 'as_alias_string_upper' "$got" '"HI"'

# --- (2) :refer installs unqualified resolution for named Vars ---
got="$("$BIN" -e "(require '[clojure.set :refer [union]]) (union #{3} #{4})" | tail -n 1)"
case "$got" in
    "#{3 4}"|"#{4 3}") echo "PASS refer_union_unqualified -> $got" ;;
    *) fail "refer_union_unqualified: unexpected '$got'" ;;
esac

# Multiple refers in one libspec.
got="$("$BIN" -e "(require '[clojure.set :refer [union intersection]]) (intersection #{1 2 3} #{2 3 4})" | tail -n 1)"
case "$got" in
    "#{2 3}"|"#{3 2}") echo "PASS refer_multi_intersection -> $got" ;;
    *) fail "refer_multi_intersection: unexpected '$got'" ;;
esac

# --- (3) :as + :refer combined ---
got="$("$BIN" -e "(require '[clojure.set :as cs :refer [union]]) (cs/intersection #{1 2} (union #{2} #{3}))" | tail -n 1)"
case "$got" in
    "#{2}") echo "PASS as_and_refer_combined -> $got" ;;
    *) fail "as_and_refer_combined: unexpected '$got'" ;;
esac

# --- (4) :refer with a private Var raises private_access_error ---
# clojure.core/-take-eager is private (D-071 Part 3). `-map-eager` was
# deleted when map went lazy (ADR-0054); `-take-eager` is the surviving
# private seq leaf used for this privacy check.
got="$("$BIN" -e "(require '[clojure.core :refer [-take-eager]])" 2>&1 || true)"
if ! grep -q 'Name error' <<<"$got"; then
    fail "refer_private_kind: missing [name_error] tag (got '$got')"
fi
if ! grep -q "private" <<<"$got"; then
    fail "refer_private_template: missing 'private' wording (got '$got')"
fi
echo "PASS refer_private_rejected"

# --- (5) :refer with a non-existent name raises symbol_unresolved ---
got="$("$BIN" -e "(require '[clojure.set :refer [no-such-fn]])" 2>&1 || true)"
if ! grep -q 'Name error' <<<"$got"; then
    fail "refer_missing_kind: missing [name_error] tag (got '$got')"
fi
if ! grep -q "no-such-fn" <<<"$got"; then
    fail "refer_missing_name: missing 'no-such-fn' (got '$got')"
fi
echo "PASS refer_missing_rejected"

# --- (6) Bare-symbol shape still works (c.4 regression check) ---
got="$("$BIN" -e "(require 'clojure.set)")"
assert_eq 'bare_symbol_still_works' "$got" 'nil'

echo ""
echo "=== phase6_16_b_4_require_libspec: all assertions passed ==="
