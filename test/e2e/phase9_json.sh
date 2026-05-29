#!/usr/bin/env bash
# test/e2e/phase9_json.sh
#
# §9.11 row 9.3 — clojure.data.json/read-str + write-str smoke.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# --- read-str cases ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/read-str "42")
EOF
) || fail "read_int: non-zero exit"
assert_eq 'read_int' "$(last_line "$got")" '42'

got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/read-str "true")
EOF
) || fail "read_true: non-zero exit"
assert_eq 'read_true' "$(last_line "$got")" 'true'

got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/read-str "null")
EOF
) || fail "read_null: non-zero exit"
assert_eq 'read_null' "$(last_line "$got")" 'nil'

got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/read-str "\"hi\"")
EOF
) || fail "read_str: non-zero exit"
assert_eq 'read_str' "$(last_line "$got")" '"hi"'

got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/read-str "[1,2,3]")
EOF
) || fail "read_arr: non-zero exit"
assert_eq 'read_arr' "$(last_line "$got")" '[1 2 3]'

got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/read-str "{\"a\":1,\"b\":2}")
EOF
) || fail "read_obj: non-zero exit"
case "$(last_line "$got")" in
    '{"a" 1, "b" 2}'|'{"b" 2, "a" 1}') echo "PASS read_obj -> $(last_line "$got")" ;;
    *) fail "read_obj: got '$(last_line "$got")'" ;;
esac

# --- write-str cases ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/write-str 42)
EOF
) || fail "write_int: non-zero exit"
assert_eq 'write_int' "$(last_line "$got")" '"42"'

got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/write-str nil)
EOF
) || fail "write_nil: non-zero exit"
assert_eq 'write_nil' "$(last_line "$got")" '"null"'

got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/write-str [1 2 3])
EOF
) || fail "write_vec: non-zero exit"
assert_eq 'write_vec' "$(last_line "$got")" '"[1,2,3]"'

got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/write-str {:a 1 :b 2})
EOF
) || fail "write_map: non-zero exit"
case "$(last_line "$got")" in
    '"{\"a\":1,\"b\":2}"'|'"{\"b\":2,\"a\":1}"') echo "PASS write_map -> $(last_line "$got")" ;;
    *) fail "write_map: got '$(last_line "$got")'" ;;
esac

# --- round-trip ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/read-str (clojure.data.json/write-str [1 "x" nil true]))
EOF
) || fail "round_trip: non-zero exit"
assert_eq 'round_trip' "$(last_line "$got")" '[1 "x" nil true]'

echo "phase9_json: 11/11 cases pass"
