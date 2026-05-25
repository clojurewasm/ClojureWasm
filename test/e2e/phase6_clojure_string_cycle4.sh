#!/usr/bin/env bash
# test/e2e/phase6_clojure_string_cycle4.sh
#
# Phase 6.9 cycle 4 EXIT smoke — capitalize + split + split-lines
# + join (final cycle; closes §9.8 row 6.9).
#
# Adds:
#   capitalize  : compose upper-case + lower-case + codepoint subs
#   split / split-lines : new rt/re-find-from + vector builder
#   join        : vector-of-strings + separator concatenation
#                  (non-string elements raise feature_not_supported
#                   pending the `str` coercion primitive landing)

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

# --- capitalize ---

got="$("$BIN" -e '(clojure.string/capitalize "hello")')"
assert_eq 'capitalize_simple' "$got" '"Hello"'

got="$("$BIN" -e '(clojure.string/capitalize "HELLO WORLD")')"
assert_eq 'capitalize_lowers_rest' "$got" '"Hello world"'

got="$("$BIN" -e '(clojure.string/capitalize "")')"
assert_eq 'capitalize_empty' "$got" '""'

got="$("$BIN" -e '(clojure.string/capitalize "a")')"
assert_eq 'capitalize_single' "$got" '"A"'

# --- split ---

got="$("$BIN" -e '(clojure.string/split "a,b,c" #",")')"
assert_eq 'split_comma' "$got" '["a" "b" "c"]'

got="$("$BIN" -e '(clojure.string/split "hello" #",")')"
assert_eq 'split_no_match' "$got" '["hello"]'

got="$("$BIN" -e '(clojure.string/split "a-b-c-d" #"-")')"
assert_eq 'split_multi_match' "$got" '["a" "b" "c" "d"]'

got="$("$BIN" -e '(clojure.string/split "" #",")')"
assert_eq 'split_empty_string' "$got" '[""]'

# --- split-lines ---

got=$("$BIN" - <<'EOF'
(clojure.string/split-lines "line1
line2
line3")
EOF
)
assert_eq 'split_lines_lf' "$got" '["line1" "line2" "line3"]'

got="$("$BIN" -e '(clojure.string/split-lines "single")')"
assert_eq 'split_lines_single' "$got" '["single"]'

# --- join ---

got="$("$BIN" -e '(clojure.string/join ["a" "b" "c"])')"
assert_eq 'join_no_sep' "$got" '"abc"'

got="$("$BIN" -e '(clojure.string/join "," ["a" "b" "c"])')"
assert_eq 'join_with_sep' "$got" '"a,b,c"'

got="$("$BIN" -e '(clojure.string/join "-" [])')"
assert_eq 'join_empty_coll' "$got" '""'

got="$("$BIN" -e '(clojure.string/join "-" ["solo"])')"
assert_eq 'join_single_element' "$got" '"solo"'

echo "phase6_clojure_string_cycle4: all 14 cases passed"
