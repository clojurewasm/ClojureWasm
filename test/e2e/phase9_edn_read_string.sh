#!/usr/bin/env bash
# test/e2e/phase9_edn_read_string.sh
#
# §9.11 row 9.2 — clojure.edn/read-string smoke.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# --- Case 1: integer ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "42"))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'edn_read_int' "$(last_line "$got")" '42'

# --- Case 2: vector ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "[1 2 3]"))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'edn_read_vector' "$(last_line "$got")" '[1 2 3]'

# --- Case 3: map ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "{:a 1 :b 2}"))
EOF
) || fail "case3: non-zero exit ($got)"
case "$(last_line "$got")" in
    "{:a 1, :b 2}"|"{:b 2, :a 1}") echo "PASS edn_read_map -> $(last_line "$got")" ;;
    *) fail "case3: got '$(last_line "$got")'" ;;
esac

# --- Case 4: set ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "#{:a :b}"))
EOF
) || fail "case4: non-zero exit ($got)"
case "$(last_line "$got")" in
    "#{:a :b}"|"#{:b :a}") echo "PASS edn_read_set -> $(last_line "$got")" ;;
    *) fail "case4: got '$(last_line "$got")'" ;;
esac

# --- Case 5: list (NOT evaluated) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "(+ 1 2)"))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'edn_read_list' "$(last_line "$got")" '(+ 1 2)'

# --- Case 6: keyword ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string ":foo/bar"))
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'edn_read_keyword' "$(last_line "$got")" ':foo/bar'

# --- Case 7: nil ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "nil"))
EOF
) || fail "case7: non-zero exit ($got)"
assert_eq 'edn_read_nil' "$(last_line "$got")" 'nil'

# --- Case 8: empty input THROWS EOF (clj parity, D-269); :eof opt overrides ---
if "$BIN" - <<'EOF' >/dev/null 2>&1
(clojure.edn/read-string "")
EOF
then fail 'case8: empty read-string should throw EOF'; fi
echo 'PASS edn_read_empty_throws -> errors'
# `:eof` sentinel suppresses the throw and returns the given value.
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string {:eof :none} ""))
EOF
) || fail "case8b: non-zero exit ($got)"
assert_eq 'edn_read_eof_opt' "$(last_line "$got")" ':none'

# --- Case 9: nested ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "[1 {:a 2} #{:x}]"))
EOF
) || fail "case9: non-zero exit ($got)"
assert_eq 'edn_read_nested' "$(last_line "$got")" '[1 {:a 2} #{:x}]'

echo "phase9_edn_read_string: 9/9 cases pass"
