#!/usr/bin/env bash
# test/e2e/phase7_symbol_value.sh
#
# Phase 7 entry T2 (ADR-0037) smoke — Symbol heap Value impl
# behind F-004 Group A slot 1. Asserts user-visible surface:
#   - (quote sym) evaluates without raising; pr-str renders with no
#     leading colon (distinct from keyword's `:foo`).
#   - (name 'ns/x) extracts the bare name.
#   - (symbol "foo") constructs; (symbol "ns" "name") constructs
#     qualified; both round-trip.
#   - (symbol? 'foo) is true; (symbol? :foo) is false (tag-dispatch
#     keeps symbol and keyword distinct).
#   - (keyword 'foo) and (symbol :foo) cross-convert via the
#     extended 1-arg surface.
#
# `(= 'foo 'foo)` is intentionally NOT exercised here: cw v1's `=`
# primitive is numeric-only (per math.zig:230 docstring — Phase 2
# limitation; finished-form `=` lands when collection equality
# arrives). Pointer-eq interning IS verified — by the differential
# test `symbol_quote_roundtrip` in src/lang/diff_test.zig, which
# checks both backends intern the same `(ns, name)` to the same
# heap pointer via `analyzeQuote`'s call into `formToValue`.

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

# --- (quote sym) pr-str with no leading colon ---
assert_eq 'quote_bare'      "$("$BIN" -e "(quote foo)")"        'foo'
assert_eq 'quote_qualified' "$("$BIN" -e "(quote ns/bar)")"     'ns/bar'

# --- (name 'sym) returns bare name (string) ---
assert_eq 'name_bare'      "$("$BIN" -e "(name (quote foo))")"     '"foo"'
assert_eq 'name_qualified' "$("$BIN" -e "(name (quote ns/x))")"    '"x"'

# --- (symbol ...) constructor ---
assert_eq 'symbol_1arg_string' "$("$BIN" -e '(symbol "foo")')"          'foo'
assert_eq 'symbol_2arg'        "$("$BIN" -e '(symbol "ns" "name")')"    'ns/name'
assert_eq 'symbol_idempotent'  "$("$BIN" -e '(symbol (quote foo))')"    'foo'

# --- (symbol? x) predicate ---
assert_eq 'symbol_q_yes' "$("$BIN" -e "(symbol? (quote foo))")"  'true'
assert_eq 'symbol_q_no'  "$("$BIN" -e "(symbol? 42)")"           'false'
assert_eq 'symbol_q_kw'  "$("$BIN" -e "(symbol? :foo)")"         'false'
assert_eq 'symbol_q_str' "$("$BIN" -e '(symbol? "foo")')"        'false'

# --- cross-conversion symbol <-> keyword ---
assert_eq 'symbol_from_keyword' "$("$BIN" -e "(symbol :foo)")"           'foo'
assert_eq 'keyword_from_symbol' "$("$BIN" -e "(keyword (quote foo))")"   ':foo'

echo "All Phase 7 symbol-value smoke checks pass."
