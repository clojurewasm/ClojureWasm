#!/usr/bin/env bash
# test/e2e/phase6_16_c_keyword_name.sh
#
# Phase 6.16.c Group C-prereq — `keyword` + `name` Tier-A
# primitives. v5 §9.1. Needed by `keywordize-keys` +
# `stringify-keys` (Group C).

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

# --- keyword 1-arg ---
got="$("$BIN" -e '(keyword "foo")')"
assert_eq 'keyword_from_string' "$got" ':foo'

# Idempotent on keyword input.
got="$("$BIN" -e '(keyword :already)')"
assert_eq 'keyword_idempotent' "$got" ':already'

# nil passthrough.
got="$("$BIN" -e '(keyword nil)')"
assert_eq 'keyword_nil_passthrough' "$got" 'nil'

# --- keyword 2-arg (qualified) ---
got="$("$BIN" -e '(keyword "ns" "name")')"
assert_eq 'keyword_qualified' "$got" ':ns/name'

# --- name on keyword ---
got="$("$BIN" -e '(name :hello)')"
assert_eq 'name_of_keyword' "$got" '"hello"'

# Qualified keyword's name is the unqualified part.
got="$("$BIN" -e '(name :my.ns/foo)')"
assert_eq 'name_of_qualified_keyword' "$got" '"foo"'

# --- name on string (idempotent) ---
got="$("$BIN" -e '(name "hi")')"
assert_eq 'name_of_string' "$got" '"hi"'

# --- round-trip ---
got="$("$BIN" -e '(name (keyword "x"))')"
assert_eq 'roundtrip_keyword_name' "$got" '"x"'

echo ""
echo "=== phase6_16_c_keyword_name: all assertions passed ==="
