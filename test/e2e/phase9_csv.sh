#!/usr/bin/env bash
# test/e2e/phase9_csv.sh
#
# §9.11 row 9.4 — clojure.data.csv/{read-csv,write-csv} smoke (RFC 4180).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# --- read-csv basic ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/read-csv "a,b,c
1,2,3")
EOF
) || fail "read_basic: non-zero exit"
assert_eq 'read_basic' "$(last_line "$got")" '[["a" "b" "c"] ["1" "2" "3"]]'

# --- read-csv quoted ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/read-csv "name,age\n\"Doe, Jane\",30")
EOF
) || fail "read_quoted: non-zero exit"
# Note: shell processes \n as literal backslash-n inside double quotes in the .clj source — for RFC newline, use heredoc raw newline
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/read-csv "name,age
\"Doe, Jane\",30")
EOF
) || fail "read_quoted2: non-zero exit"
assert_eq 'read_quoted_comma' "$(last_line "$got")" '[["name" "age"] ["Doe, Jane" "30"]]'

# --- read-csv escaped double-quote ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/read-csv "x\n\"he said \"\"hi\"\"\"")
EOF
) || fail "read_escq_setup"
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/read-csv "x
\"he said \"\"hi\"\"\"")
EOF
) || fail "read_escq: non-zero exit"
assert_eq 'read_escaped_dquote' "$(last_line "$got")" '[["x"] ["he said \"hi\""]]'

# --- write-csv basic ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/write-csv [["a" "b"] ["1" "2"]])
EOF
) || fail "write_basic: non-zero exit"
assert_eq 'write_basic' "$(last_line "$got")" '"a,b\n1,2\n"'

# --- write-csv with comma triggers quoting ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/write-csv [["name" "age"] ["Doe, Jane" "30"]])
EOF
) || fail "write_quoted: non-zero exit"
assert_eq 'write_with_comma' "$(last_line "$got")" '"name,age\n\"Doe, Jane\",30\n"'

# --- write-csv with embedded double-quote ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/write-csv [["x"] ["he said \"hi\""]])
EOF
) || fail "write_dquote: non-zero exit"
assert_eq 'write_embedded_dquote' "$(last_line "$got")" '"x\n\"he said \"\"hi\"\"\"\n"'

# --- round-trip ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/read-csv (clojure.data.csv/write-csv [["a" "b,c"] ["d" "e\"f"]]))
EOF
) || fail "round_trip: non-zero exit"
assert_eq 'round_trip' "$(last_line "$got")" '[["a" "b,c"] ["d" "e\"f"]]'

echo "phase9_csv: 7/7 cases pass"
