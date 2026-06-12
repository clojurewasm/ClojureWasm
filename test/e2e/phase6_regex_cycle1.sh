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

# re-seq — successive non-overlapping matches (via the re-find-from primitive)
got="$("$BIN" -e '(re-seq #"\d+" "a1b22c333")')"
assert_eq 'reseq_nums' "$got" '("1" "22" "333")'
got="$("$BIN" -e '(re-seq #"[a-z]+" "ab cd ef")')"
assert_eq 'reseq_words' "$got" '("ab" "cd" "ef")'
got="$("$BIN" -e '(re-seq #"\d+" "abc")')"
assert_eq 'reseq_none' "$got" 'nil'
got="$("$BIN" -e '(re-find-from #"\d+" "a1b22" 2)')"
assert_eq 'refindfrom' "$got" '["22" 3 5]'

# --- capturing groups (D-093): re-find/re-matches/re-seq return [whole g1 …] ---
got="$("$BIN" -e '(re-find #"(\w)(\w)" "ab")')"
assert_eq 'group_re_find' "$got" '["ab" "a" "b"]'
got="$("$BIN" -e '(re-matches #"(\d)(\d)" "42")')"
assert_eq 'group_re_matches' "$got" '["42" "4" "2"]'
# nested groups number outer-then-inner; alternation participates
got="$("$BIN" -e '(re-find #"((\d)(\d))" "42")')"
assert_eq 'group_nested' "$got" '["42" "42" "4" "2"]'
# an optional group that does not participate is nil
got="$("$BIN" -e '(re-find #"(a)(b)?" "a")')"
assert_eq 'group_optional_nil' "$got" '["a" "a" nil]'
# non-capturing (?:…) is skipped in the group vector
got="$("$BIN" -e '(re-find #"(?:\w)(\w)" "ab")')"
assert_eq 'group_non_capturing' "$got" '["ab" "b"]'
# greedy backtracking still finds the leftmost-greedy submatch
got="$("$BIN" -e '(re-matches #"(a+)(a+)" "aaaa")')"
assert_eq 'group_greedy' "$got" '["aaaa" "aaa" "a"]'
# re-seq yields a group vector per match
got="$("$BIN" -e '(re-seq #"(\d)(\d)" "1234")')"
assert_eq 'group_re_seq' "$got" '(["12" "1" "2"] ["34" "3" "4"])'
# no groups → whole-match string (no regression)
got="$("$BIN" -e '(re-find #"\w+" "hi")')"
assert_eq 'group_none_string' "$got" '"hi"'
# pr/prn/println render the `#"…"` reader form (JVM print-method Pattern);
# str renders the raw pattern (Pattern.toString). §A26 regex-print sweep.
got="$("$BIN" - <<'CLJ'
(prn (re-pattern "a.c"))
CLJ
)"
assert_eq 'regex_pr_reader_form' "$(printf '%s' "$got" | head -1)" '#"a.c"'
got="$("$BIN" - <<'CLJ'
(prn (str #"a.c"))
CLJ
)"
assert_eq 'regex_str_raw' "$(printf '%s' "$got" | head -1)" '"a.c"'

# INV-1: a nested-counted-repetition compile-bomb on untrusted pattern input
# (`(a{65535}){65535}` would expand to ~4.3e9 insts) is a CATCHABLE
# IllegalArgumentException, not an OOM / process kill. The matcher is Pike-NFA
# (ReDoS-immune for untrusted input); this guards the compile side.
got="$("$BIN" -e '(try (do (re-pattern "(a{65535}){65535}") :uncaught) (catch IllegalArgumentException _ :caught))')"
assert_eq 'inv1_compile_bomb_catchable' "$got" ':caught'

echo "phase6_regex_cycle1: all 25 cases passed"
