#!/usr/bin/env bash
# test/e2e/phase6_16_d_clojure_string_shim.sh
#
# Phase 6.16.d — clojure.string Pattern B2 shim verification.
# v5 §8.1 + §9.2.
#
# Each public Var (upper-case / lower-case / ... / reverse) is now a
# 1-line shim defn in `lang/clj/clojure/string.clj` over a private
# `-name` leaf in `lang/primitive/string.zig::LEAF_ENTRIES`. This
# test asserts:
#   1. Public Vars still work via the shim (surface API preserved).
#   2. User-ns access to `clojure.string/-upper-case` qualified
#      raises `private_access_error` (ADR-0033 D4 leaf privacy).

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

# --- (1) shimmed Vars still work ---
got="$("$BIN" -e '(clojure.string/upper-case "hi")')"
assert_eq 'upper_case_via_shim' "$got" '"HI"'

got="$("$BIN" -e '(clojure.string/lower-case "BYE")')"
assert_eq 'lower_case_via_shim' "$got" '"bye"'

got="$("$BIN" -e '(clojure.string/trim "  hi  ")')"
assert_eq 'trim_via_shim' "$got" '"hi"'

got="$("$BIN" -e '(clojure.string/triml "  hi")')"
assert_eq 'triml_via_shim' "$got" '"hi"'

got="$("$BIN" -e '(clojure.string/trimr "hi  ")')"
assert_eq 'trimr_via_shim' "$got" '"hi"'

got="$("$BIN" -e '(clojure.string/trim-newline "hi\n")')"
assert_eq 'trim_newline_via_shim' "$got" '"hi"'

got="$("$BIN" -e '(clojure.string/starts-with? "hello" "he")')"
assert_eq 'starts_with_via_shim' "$got" 'true'

got="$("$BIN" -e '(clojure.string/ends-with? "hello" "lo")')"
assert_eq 'ends_with_via_shim' "$got" 'true'

got="$("$BIN" -e '(clojure.string/includes? "hello" "ell")')"
assert_eq 'includes_via_shim' "$got" 'true'

got="$("$BIN" -e '(clojure.string/index-of "hello" "l")')"
assert_eq 'index_of_via_shim' "$got" '2'

got="$("$BIN" -e '(clojure.string/last-index-of "hello" "l")')"
assert_eq 'last_index_of_via_shim' "$got" '3'

got="$("$BIN" -e '(clojure.string/reverse "abc")')"
assert_eq 'reverse_via_shim' "$got" '"cba"'

# --- (2) private leaf qualified access is denied from user ns ---
got="$("$BIN" -e '(clojure.string/-upper-case "hi")' 2>&1 || true)"
if ! grep -q 'name_error' <<<"$got"; then
    fail "private_leaf_qualified_kind: missing [name_error] (got '$got')"
fi
if ! grep -q 'private' <<<"$got"; then
    fail "private_leaf_qualified_template: missing 'private' (got '$got')"
fi
echo "PASS private_leaf_user_qualified_denied"

# --- (3) intra-ns access (in-ns clojure.string) works ---
got="$("$BIN" -e "(in-ns 'clojure.string) (-upper-case \"hi\")" | tail -n 1)"
assert_eq 'private_leaf_same_ns_works' "$got" '"HI"'

echo ""
echo "=== phase6_16_d_clojure_string_shim: all assertions passed ==="
