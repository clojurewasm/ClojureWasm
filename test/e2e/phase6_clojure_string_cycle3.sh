#!/usr/bin/env bash
# test/e2e/phase6_clojure_string_cycle3.sh
#
# Phase 6.9 cycle 3 EXIT smoke — indexing + simple replace +
# escape + reverse (6 vars).
#
# Adds:
#   index-of / last-index-of (codepoint index; DIVERGENCE D1)
#   replace string-only / replace-first string-only
#     (regex / char-char forms raise feature_not_supported until
#      D-051 cycle 3 lands captures)
#   escape (cmap: array_map or fn; replacement must be nil or string)
#   reverse (codepoint reverse)

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

# --- index-of / last-index-of ---

got="$("$BIN" -e '(clojure.string/index-of "hello world" "world")')"
assert_eq 'index_of_hit' "$got" '6'

got="$("$BIN" -e '(clojure.string/index-of "hello" "x")')"
assert_eq 'index_of_miss_returns_nil' "$got" 'nil'

# Codepoint index (DIVERGENCE D1): "あbいc" — "い" is at codepoint 2,
# not byte index 4.
got="$("$BIN" -e '(clojure.string/index-of "あbいc" "い")')"
assert_eq 'index_of_codepoint_jp' "$got" '2'

got="$("$BIN" -e '(clojure.string/last-index-of "hello hello" "hello")')"
assert_eq 'last_index_of_hit' "$got" '6'

got="$("$BIN" -e '(clojure.string/last-index-of "hello" "x")')"
assert_eq 'last_index_of_miss' "$got" 'nil'

# --- replace / replace-first (string-only) ---

got="$("$BIN" -e '(clojure.string/replace "hello world" "l" "L")')"
assert_eq 'replace_string_all' "$got" '"heLLo worLd"'

got="$("$BIN" -e '(clojure.string/replace "hi" "x" "Y")')"
assert_eq 'replace_no_match' "$got" '"hi"'

got="$("$BIN" -e '(clojure.string/replace-first "hello world" "l" "L")')"
assert_eq 'replace_first' "$got" '"heLlo world"'

got="$("$BIN" -e '(clojure.string/replace "" "x" "y")')"
assert_eq 'replace_empty_haystack' "$got" '""'

# --- escape (fn + empty-map; \char reader literal not yet
#     implemented so non-empty map-cmap testing waits for that) ---

# fn cmap returning nil for every char → identity.
got="$("$BIN" -e '(clojure.string/escape "abc" (fn* [c] nil))')"
assert_eq 'escape_fn_nil_passthrough' "$got" '"abc"'

# fn cmap returning constant string for every char → 3 × "X".
got="$("$BIN" -e '(clojure.string/escape "abc" (fn* [c] "X"))')"
assert_eq 'escape_fn_constant' "$got" '"XXX"'

# Map cmap path — now testable since `{...}` literal-as-Value AND the
# `\<char>` reader literal both land (D-059 discharged §A26). Char-literal
# map keys need stdin (the `\` is shell-hostile through -e); first line is prn.
got="$("$BIN" - <<'CLJ' 2>/dev/null
(prn (clojure.string/escape "a&b<c" {\& "&amp;" \< "&lt;"}))
CLJ
)"
assert_eq 'escape_html_entities' "$(printf '%s' "$got" | head -1)" '"a&amp;b&lt;c"'
got="$("$BIN" -e '(clojure.string/escape "xy" {})')"
assert_eq 'escape_empty_map_passthrough' "$got" '"xy"'

# --- reverse ---

got="$("$BIN" -e '(clojure.string/reverse "hello")')"
assert_eq 'reverse_ascii' "$got" '"olleh"'

got="$("$BIN" -e '(clojure.string/reverse "")')"
assert_eq 'reverse_empty' "$got" '""'

# Codepoint reverse — "あいう" → "ういあ" (3 codepoints, NOT byte reverse).
got="$("$BIN" -e '(clojure.string/reverse "あいう")')"
assert_eq 'reverse_codepoint_jp' "$got" '"ういあ"'

echo "phase6_clojure_string_cycle3: all 13 cases passed"
# (13 = 5 index + 4 replace + 2 escape-fn + 3 reverse — empty-map
#  cmap test deferred to D-059 close)
