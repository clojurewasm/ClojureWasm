#!/usr/bin/env bash
# test/e2e/phase9_json.sh
#
# §9.11 row 9.3 — clojure.data.json/read-str + write-str smoke.

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

# --- read-str cases ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str "42"))
EOF
) || fail "read_int: non-zero exit"
assert_eq 'read_int' "$(last_line "$got")" '42'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str "true"))
EOF
) || fail "read_true: non-zero exit"
assert_eq 'read_true' "$(last_line "$got")" 'true'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str "null"))
EOF
) || fail "read_null: non-zero exit"
assert_eq 'read_null' "$(last_line "$got")" 'nil'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str "\"hi\""))
EOF
) || fail "read_str: non-zero exit"
assert_eq 'read_str' "$(last_line "$got")" '"hi"'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str "[1,2,3]"))
EOF
) || fail "read_arr: non-zero exit"
assert_eq 'read_arr' "$(last_line "$got")" '[1 2 3]'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str "{\"a\":1,\"b\":2}"))
EOF
) || fail "read_obj: non-zero exit"
case "$(last_line "$got")" in
    '{"a" 1, "b" 2}'|'{"b" 2, "a" 1}') echo "PASS read_obj -> $(last_line "$got")" ;;
    *) fail "read_obj: got '$(last_line "$got")'" ;;
esac

# --- write-str cases ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/write-str 42))
EOF
) || fail "write_int: non-zero exit"
assert_eq 'write_int' "$(last_line "$got")" '"42"'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/write-str nil))
EOF
) || fail "write_nil: non-zero exit"
assert_eq 'write_nil' "$(last_line "$got")" '"null"'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/write-str [1 2 3]))
EOF
) || fail "write_vec: non-zero exit"
assert_eq 'write_vec' "$(last_line "$got")" '"[1,2,3]"'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/write-str {:a 1 :b 2}))
EOF
) || fail "write_map: non-zero exit"
case "$(last_line "$got")" in
    '"{\"a\":1,\"b\":2}"'|'"{\"b\":2,\"a\":1}"') echo "PASS write_map -> $(last_line "$got")" ;;
    *) fail "write_map: got '$(last_line "$got")'" ;;
esac

# --- round-trip ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str (clojure.data.json/write-str [1 "x" nil true])))
EOF
) || fail "round_trip: non-zero exit"
assert_eq 'round_trip' "$(last_line "$got")" '[1 "x" nil true]'

# --- large map (>8 entries → hash_map/HAMT, not array_map): write-str used to
# error ("not supported") on any hash_map. Order is HAMT-dependent, so assert
# round-trip identity (order-independent map =) rather than the exact string. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(let [m (into {} (map (fn [i] [(str i) i]) (range 50)))]
  (prn (= m (clojure.data.json/read-str (clojure.data.json/write-str m)))))
EOF
) || fail "write_hashmap_roundtrip: non-zero exit"
assert_eq 'write_hashmap_roundtrip' "$(last_line "$got")" 'true'

# --- float write: JVM data.json delegates to Double.toString (scientific
# notation outside the decimal window) — must match cljw's pr-str float
# form, NOT Zig's `{d}`. D-171 (sibling of D-166 print.printFloat). ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/write-str [1.0e7 0.0001 3.14 1.5e-5 2.5e16]))
EOF
) || fail "write_float: non-zero exit"
assert_eq 'write_float' "$(last_line "$got")" '"[1.0E7,1.0E-4,3.14,1.5E-5,2.5E16]"'

# --- BigInt write: JVM data.json writes `(str x)` → plain digits, no `N`
# suffix (printBigInt's `N` is pr-str-only). D-182 write-side. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/write-str [10N 12345678901234567890N]))
EOF
) || fail "write_bigint: non-zero exit"
assert_eq 'write_bigint' "$(last_line "$got")" '"[10,12345678901234567890]"'

# --- Long read: a JSON integer within i64 reads as a Long (JVM data.json
# parses Long-range ints as Long); after D-165 C7 a (2^47, i64] value is a
# heap Long that prints WITHOUT N, matching clj. D-182 read-side. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str "[1, 999999999999999999, 2]"))
EOF
) || fail "read_long: non-zero exit"
assert_eq 'read_long' "$(last_line "$got")" '[1 999999999999999999 2]'
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (= (clojure.data.json/read-str "999999999999999999") 999999999999999999))
EOF
) || fail "read_bigint_eq: non-zero exit"
assert_eq 'read_bigint_eq' "$(last_line "$got")" 'true'
# Beyond i64 → std.json hands a number_string → BigInt (D-182 read residual
# landed). 2^65 (> 2^64) exercises the D-047-safe parseBase10 path.
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str "[1, 36893488147419103232, 2.5]"))
EOF
) || fail "read_bigint_huge: non-zero exit"
assert_eq 'read_bigint_huge' "$(last_line "$got")" '[1 36893488147419103232N 2.5]'

echo "phase9_json: 16/16 cases pass"
