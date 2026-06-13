#!/usr/bin/env bash
# test/e2e/phase14_re_matcher.sh — re-matcher / java.util.regex.Matcher
# host_instance (the instaparse re-match-at-front pull): lookingAt / matches /
# find / group / groupCount / start / end / re-groups / 1-arity re-find, plus
# the StringBuilder int-capacity ctor + 4-arity .append that Segment.toString
# requires. All expected values oracle-verified against clj 2026-06-13
# (private/notes/p14-instaparse-campaign.md).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n"; }

got=$("$BIN" - <<'EOF' 2>/dev/null
(let [m (re-matcher #"a+" "aaab")] (prn [(.lookingAt m) (.group m)]))
(let [m (re-matcher #"b+" "aaab")] (prn [(.lookingAt m)]))
(let [m (re-matcher #"(a)(b)?" "ac")] (prn [(.lookingAt m) (.group m) (.group m 1) (.group m 2) (.groupCount m)]))
(let [m (re-matcher #"\d+" "a12b345")] (prn [(.find m) (.group m) (.start m) (.end m) (.find m) (.group m) (.find m)]))
(let [m (re-matcher #"\d+" "a12b34")] (prn [(re-find m) (re-find m) (re-find m)]))
(let [m (re-matcher #"(\d)(\d)" "a12")] (prn (when (.find m) (re-groups m))))
(let [m (re-matcher #"abc" "abcd")] (prn [(.matches m) (.lookingAt m)]))
(let [m (re-matcher #"a*" "bbb")] (prn [(.find m) (.group m) (.start m) (.end m) (.find m) (.start m)]))
(prn (class (re-matcher #"a" "a")))
(prn (str (StringBuilder. 5)))
(let [sb (StringBuilder.)] (.append sb "hello world" 6 11) (prn (.toString sb)))
EOF
) || true
want='[true "aaa"]
[false]
[true "a" "a" nil 2]
[true "12" 1 3 true "345" false]
["12" "34" nil]
["12" "1" "2"]
[false true]
[true "" 0 0 true 1]
java.util.regex.Matcher
""
"world"'
assert_eq "matcher_oracle_table" "$got" "$want"

# Unmatched (.group m) raises (JVM: IllegalStateException "No match found").
if err=$("$BIN" -e '(let [m (re-matcher #"b" "a")] (.group m))' 2>&1); then
  fail "group_without_match: expected non-zero exit, got '$err'"
fi
echo "$err" | grep -q "No match found" || fail "group_without_match: message missing 'No match found': $err"
echo "PASS group_without_match"

echo "OK phase14_re_matcher"
