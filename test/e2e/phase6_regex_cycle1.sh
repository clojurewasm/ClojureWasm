#!/usr/bin/env bash
# test/e2e/phase6_regex_cycle1.sh
#
# ADR-0031 Alt 2 cycle 1 EXIT smoke (Phase 6.6).
#
# Walks the end-to-end path: tokenizer recognises `#"..."`,
# reader emits Form.regex_literal, analyzer compiles to a regex
# Value via runtime/regex/value.zig, lang/primitive/regex.zig
# dispatches `re-find` / `re-matches` / `re-pattern` against
# the Pike VM in runtime/regex/match.zig.
#
# Cycle 2-5 follow-ups (D-051): lazy DFA, capture groups,
# (?i), PatternSyntaxException-aligned errors.

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

# 1. ADR-0031 cycle-1 acceptance: (re-find #"\d+" "abc123") -> "123".
got="$("$BIN" -e '(re-find #"\d+" "abc123")')"
assert_eq 'cycle1_exit_smoke_re_find_digits' "$got" '"123"'

# 2. Alternation reaches the surface.
got="$("$BIN" -e '(re-find #"a|b" "xby")')"
assert_eq 'cycle1_alt' "$got" '"b"'

# 3. Greedy star.
got="$("$BIN" -e '(re-find #"a*" "aaa")')"
assert_eq 'cycle1_star' "$got" '"aaa"'

# 4. Character class + range.
got="$("$BIN" -e '(re-find #"[a-z]+" "ABCdef")')"
assert_eq 'cycle1_class_range' "$got" '"def"'

# 5. Whitespace escape.
got="$("$BIN" -e '(re-find #"\w+" " hello world ")')"
assert_eq 'cycle1_word_escape' "$got" '"hello"'

# 6. Anchored re-matches succeeds only on full string.
got="$("$BIN" -e '(re-matches #"\d+" "123")')"
assert_eq 'cycle1_re_matches_full' "$got" '"123"'

got="$("$BIN" -e '(re-matches #"\d+" "123abc")')"
assert_eq 'cycle1_re_matches_partial_nil' "$got" 'nil'

# 7. re-pattern produces a regex Value that re-find accepts.
# Note: string literal `\\d` becomes `\d` after string-escape
# decoding, which is what the regex compiler sees.
got="$("$BIN" -e '(re-find (re-pattern "\\d") "x9y")')"
assert_eq 'cycle1_re_pattern_round_trip' "$got" '"9"'

# 8. Caret + dollar anchors.
got="$("$BIN" -e '(re-find #"^abc$" "abc")')"
assert_eq 'cycle1_anchor_full' "$got" '"abc"'

got="$("$BIN" -e '(re-find #"^abc$" "xabc")')"
assert_eq 'cycle1_anchor_no_match' "$got" 'nil'

echo "phase6_regex_cycle1: all 10 cases passed"
