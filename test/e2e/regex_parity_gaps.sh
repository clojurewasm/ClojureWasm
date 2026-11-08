#!/usr/bin/env bash
# test/e2e/regex_parity_gaps.sh
#
# D-447 close-out: the regex gaps are either IMPLEMENTED (lookbehind, named
# groups, \A \z \Z, nested class unions + && intersection, empty alternatives)
# or PERMANENTLY DECLINED (backreferences — AD-060, the RE2 posture: a
# backreference forces a backtracking engine, and ADR-0031's Pike-NFA
# linear-time guarantee is the property that lets untrusted patterns run).
#
# The implemented half is clj-byte-matched in
# test/diff/clj_corpus/regex_equivalence.txt (15 goldens appended 2026-08-05);
# this file pins the SIGNAL SPLIT, which the corpus cannot express:
#   - a MALFORMED pattern raises the CATCHABLE invalid-pattern error
#     (Java: PatternSyntaxException, catchable), and
#   - a VALID-in-Java backreference raises the UNCATCHABLE unsupported-feature
#     error that a (catch Throwable …) must NOT swallow.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { awk 'END { print }' <<< "$1"; }

# --- the implemented features, one smoke each (full set in the corpus) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn [(re-find #"(?<=a)b" "ab")
      (re-find #"(?<year>\d{4})" "y2024")
      (.group (doto (re-matcher #"(?<n>b)c" "abc") .find) "n")
      (re-find #"\Aab" "abc")
      (re-find #"bc\z" "abc")
      (re-find #"bc\Z" "abc\n")
      (re-find #"[a-c[x-z]]+" "bxya!")
      (re-find #"[a-z&&[^m-p]]+" "klmnoqr")])
EOF
) || fail "implemented_features: non-zero exit"
want='["b" ["2024" "2024"] "b" "ab" "bc" "bc" "bxya" "kl"]'
[[ "$(last_line "$got")" == "$want" ]] || fail "implemented_features: got '$(last_line "$got")', want '$want'"
echo "PASS implemented_features"

# --- a malformed pattern is CATCHABLE (Java: PatternSyntaxException) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn [(try (re-pattern "(") (catch Throwable _ :caught))
      (try (re-pattern "[a") (catch Throwable _ :caught))
      (try (re-pattern "a{2,1}") (catch Throwable _ :caught))])
EOF
) || fail "malformed_catchable: non-zero exit"
[[ "$(last_line "$got")" == '[:caught :caught :caught]' ]] \
    || fail "malformed_catchable: got '$(last_line "$got")'"
echo "PASS malformed_catchable"

# --- AD-060 pin: a backreference stays UNCATCHABLE ---
got=$("$BIN" - <<'EOF' 2>&1 || true
(prn (try (re-pattern "(a)\\1") :NOT-RAISED (catch Throwable _ :swallowed)))
EOF
)
grep -q 'is not supported in ClojureWasm' <<< "$got" \
    || fail "backref_uncatchable: expected the unsupported-feature raise, got '$got'"
grep -q 'regex backreference' <<< "$got" \
    || fail "backref_uncatchable: expected the raise to name the backreference, got '$got'"
grep -qx ':swallowed' <<< "$got" \
    && fail "backref_uncatchable: a catch swallowed the backreference raise"
echo "PASS backref_uncatchable"

echo "regex_parity_gaps: 3/3 cases pass"
