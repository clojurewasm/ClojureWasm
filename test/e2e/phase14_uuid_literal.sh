#!/usr/bin/env bash
# test/e2e/phase14_uuid_literal.sh
#
# D-200 cycle 3 / ADR-0074 — `#uuid "…"` reads to a real `.uuid` value type.
# One coherent UUID representation across the reader literal, `random-uuid`,
# `parse-uuid`, and `java.util.UUID/randomUUID`: EDN round-trips through
# pr-str, answers `uuid?` / `class` / `instance?`, and `=` by the 128 bits.
# (`#inst`/Date is a separate later ADR; the root `*data-readers*` ships the
# `uuid` reader only.)
#
# Assertions use value-returning exprs (not println, which in stdin mode
# appends a trailing `nil` result line). pr-str is checked by a prefix probe
# + the read-string round-trip (the defining reader-literal property).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

U="550e8400-e29b-41d4-a716-446655440000"

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- Case 1: #uuid reads without a binding (root data-reader) + is uuid? ---
assert_eq 'uuid_literal_pred' "$("$BIN" -e "(uuid? #uuid \"$U\")")" 'true'

# --- Case 2: pr-str produces the `#uuid "…"` reader form (prefix probe) ---
assert_eq 'uuid_pr_str_prefix' "$("$BIN" -e "(subs (pr-str #uuid \"$U\") 0 6)")" '"#uuid "'

# --- Case 3: read-string of pr-str re-reads to an equal value (round-trip) ---
assert_eq 'uuid_read_roundtrip' \
    "$("$BIN" -e "(= #uuid \"$U\" (read-string (pr-str #uuid \"$U\")))")" 'true'

# --- Case 4: = by the 128 bits (distinct allocations, same/different bytes) ---
assert_eq 'uuid_value_equality' "$("$BIN" -e "(= #uuid \"$U\" #uuid \"$U\")")" 'true'
assert_eq 'uuid_value_inequality' \
    "$("$BIN" -e "(= #uuid \"$U\" #uuid \"00000000-0000-0000-0000-000000000000\")")" 'false'

# --- Case 5: (str x) is the bare canonical (UUID toString), not the reader form ---
assert_eq 'uuid_str' "$("$BIN" -e "(str #uuid \"$U\")")" "\"$U\""

# --- Case 6: class + instance? (cljw native simple-name convention) ---
assert_eq 'uuid_class' "$("$BIN" -e "(class #uuid \"$U\")")" 'UUID'
assert_eq 'uuid_instance' "$("$BIN" -e "(instance? java.util.UUID #uuid \"$U\")")" 'true'

# --- Case 7: the three constructors all return uuid? values (coherence) ---
assert_eq 'random_uuid_is_uuid' "$("$BIN" -e '(uuid? (random-uuid))')" 'true'
assert_eq 'parse_uuid_is_uuid' "$("$BIN" -e "(uuid? (parse-uuid \"$U\"))")" 'true'
assert_eq 'java_random_is_uuid' "$("$BIN" -e '(uuid? (java.util.UUID/randomUUID))')" 'true'

# --- Case 8: parse-uuid returns nil on bad input (never throws) ---
assert_eq 'parse_uuid_bad_nil' "$("$BIN" -e '(parse-uuid "not-a-uuid")')" 'nil'

# --- Case 9: a malformed #uuid literal raises "Invalid UUID string" ---
if out=$("$BIN" -e '#uuid "not-a-uuid"' 2>&1); then
    fail "case9: expected non-zero exit, got success ($out)"
fi
case "$out" in
    *"Invalid UUID string: not-a-uuid"*) echo "PASS uuid_bad_literal_raises -> (clj-parity error)" ;;
    *) fail "case9: wrong error: $out" ;;
esac

# --- Case 10: both backends agree (dual-backend parity) ---
assert_eq 'backend_parity' "$("$BIN" --compare -e "(uuid? #uuid \"$U\")")" 'OK true'

# --- Case 11: a UUID works as a map KEY / set element / distinct dedup.
#     (Regression: hash + `=` alone are NOT enough — the map/set HAMT's
#     rt-free `keyEqValue` needs a `.uuid` arm too, else lookup silently
#     misses despite a matching hash.) ---
assert_eq 'uuid_map_key'  "$("$BIN" -e "(get {#uuid \"$U\" :v} #uuid \"$U\")")" ':v'
assert_eq 'uuid_set_elem' "$("$BIN" -e "(contains? #{#uuid \"$U\"} #uuid \"$U\")")" 'true'
assert_eq 'uuid_distinct' "$("$BIN" -e "(count (distinct [#uuid \"$U\" #uuid \"$U\" #uuid \"00000000-0000-0000-0000-000000000000\"]))")" '2'

# --- java.util.UUID/fromString static (= parse-uuid; throws on malformed) ---
assert_eq 'from_string'   "$("$BIN" -e "(uuid? (java.util.UUID/fromString \"$U\"))")" 'true'
assert_eq 'from_str_eq'   "$("$BIN" -e "(= (java.util.UUID/fromString \"$U\") #uuid \"$U\")")" 'true'
out="$("$BIN" -e '(java.util.UUID/fromString "not-a-uuid")' 2>&1 || true)"; case "$out" in *uuid*|*UUID*) echo "PASS from_str_bad -> err" ;; *) fail "from_str_bad: $out" ;; esac

echo "OK — phase14_uuid_literal (19 cases) green"
