#!/usr/bin/env bash
# test/e2e/phase14_pattern_quote.sh
#
# java.util.regex.Pattern/quote — wraps a string in \Q…\E so it matches
# literally as a regex (regex metacharacters lose their meaning). The first
# real feature gap the library ladder found at cuerdas rung 8 (capitalize et
# al. build literal patterns via Pattern/quote). cljw's regex engine already
# honors \Q…\E; only this static-method surface was an empty reservation.
#
# Assertions are behavioural (`=` against the expected raw string, and
# re-find matching) rather than pr-str form, to avoid shell + print
# backslash-escaping ambiguity.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# (1) the basic transform equals "\Qa.b*c\E" (the \\ in the shell-literal is one
#     backslash in the Clojure string, matching the raw quote() output)
assert_eq 'quote_basic' "$(last_line "$("$BIN" -e '(= (java.util.regex.Pattern/quote "a.b*c") "\\Qa.b*c\\E")')")" 'true'
# (2) empty string → "\Q\E"
assert_eq 'quote_empty' "$(last_line "$("$BIN" -e '(= (java.util.regex.Pattern/quote "") "\\Q\\E")')")" 'true'
# (3) the quoted pattern matches the literal text (the . is NOT a wildcard)
assert_eq 'quoted_matches_literal' "$(last_line "$("$BIN" -e '(boolean (re-find (re-pattern (java.util.regex.Pattern/quote "a.c")) "xa.cy"))')")" 'true'
# (4) …and does NOT match where the literal differs (. is not a wildcard)
assert_eq 'quoted_no_wildcard' "$(last_line "$("$BIN" -e '(boolean (re-find (re-pattern (java.util.regex.Pattern/quote "a.c")) "xaXcy"))')")" 'false'
# (5) embedded \E is handled (clj splits it as \E\\E\Q); the quoted pattern still
#     matches the literal text containing a backslash-E
assert_eq 'quoted_with_E_literal' "$(last_line "$("$BIN" -e '(boolean (re-find (re-pattern (java.util.regex.Pattern/quote "a\\Eb")) "za\\Ebz"))')")" 'true'
