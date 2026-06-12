#!/usr/bin/env bash
# test/e2e/phase14_unicode_case.sh — D-057: Unicode case mapping.
# The JVM 3-way split, reproduced exactly (oracle-verified 2026-06-13):
#   - clojure.string/upper-case|lower-case|capitalize = String.toUpperCase:
#     FULL mapping incl. SpecialCasing (ß→SS, ﬁ→FI, ŉ→ʼN, İ→i+̇) +
#     Final_Sigma (ΣΟΦΟΣ → σοφος with a final ς).
#   - Character/toUpperCase|toLowerCase = SIMPLE 1:1 (ß stays ß; ä→Ä; Σ→σ).
#   - regex (?iu) = simple-map fold orbit (σ~Σ~ς match; ß does NOT match "ss").
# Non-ASCII inside a [...] class under (?iu) stays an explicit
# not-implemented (the byte-bitmap CharClass deferral — see D-057 notes).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.string/upper-case "straße"))
(prn (clojure.string/lower-case "ÄÖÜ"))
(prn (clojure.string/upper-case "ﬁre"))
(prn (clojure.string/lower-case "ΣΟΦΟΣ"))
(prn (clojure.string/upper-case "ñandú"))
(prn (clojure.string/capitalize "ärger"))
(prn (clojure.string/capitalize "ßx"))
(prn (clojure.string/upper-case "ŉ"))
(prn (Character/toUpperCase \ß))
(prn (Character/toUpperCase \ä))
(prn (Character/toLowerCase \Σ))
EOF
) || true
want='"STRASSE"
"äöü"
"FIRE"
"σοφος"
"ÑANDÚ"
"Ärger"
"SSx"
"ʼN"
\ß
\Ä
\σ'
assert_eq 'string_full_vs_char_simple' "$got" "$want"

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (re-find #"(?iu)Ä" "ä"))
(prn (re-find #"(?iu)σ" "Σ"))
(prn (re-find #"(?iu)ς" "σ"))
(prn (re-find #"(?iu)ss" "ß"))
(prn (re-find #"(?ui)öl+" "ÖLLL"))
(prn (re-find #"(?i)Ä" "ä"))
EOF
) || true
want='"ä"
"Σ"
"σ"
nil
"ÖLLL"
nil'
assert_eq 'regex_unicode_fold_orbit' "$got" "$want"

echo "OK — phase14_unicode_case (2 cases) green"
