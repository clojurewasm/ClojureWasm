#!/usr/bin/env bash
# test/e2e/phase6_clojure_set_cycle2.sh
#
# Phase 6.10 cycle 2 — clojure.set Group B (rename-keys + map-invert).
# Adds `rt/hash-map` constructor + map pr-str alongside.

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

# --- hash-map constructor + pr-str of maps ---

got="$("$BIN" -e '(hash-map :a 1)')"
assert_eq 'hash_map_one_entry' "$got" '{:a 1}'

got="$("$BIN" -e '(hash-map)')"
assert_eq 'hash_map_empty' "$got" '{}'

# --- rename-keys ---

# Single key rename produces the renamed key at the end (dissoc+assoc
# re-insertion). Value content matches JVM semantics; entry order is
# implementation-defined post-rename.
got="$("$BIN" -e '(clojure.set/rename-keys (hash-map :a 1 :b 2) (hash-map :a :A))')"
assert_eq 'rename_keys_simple' "$got" '{:b 2, :A 1}'

# Round-trip (rename + un-rename) preserves entries (entry order is
# implementation-defined; JVM also re-orders ArrayMap entries on
# dissoc/assoc).
got2="$("$BIN" -e '(clojure.set/rename-keys (clojure.set/rename-keys (hash-map :a 1 :b 2) (hash-map :a :A)) (hash-map :A :a))')"
assert_eq 'rename_keys_round_trip' "$got2" '{:b 2, :a 1}'

# rename a key whose source is absent → no-op for that mapping.
got="$("$BIN" -e '(clojure.set/rename-keys (hash-map :a 1) (hash-map :missing :gone))')"
assert_eq 'rename_keys_absent_source' "$got" '{:a 1}'

# rename to a key that already exists — value should overwrite.
got="$("$BIN" -e '(clojure.set/rename-keys (hash-map :a 1 :b 2) (hash-map :a :b))')"
assert_eq 'rename_keys_collision' "$got" '{:b 1}'

# empty rename-map → identity
got="$("$BIN" -e '(clojure.set/rename-keys (hash-map :x 9) (hash-map))')"
assert_eq 'rename_keys_empty_rename' "$got" '{:x 9}'

# --- map-invert ---

got="$("$BIN" -e '(clojure.set/map-invert (hash-map :a 1 :b 2))')"
# Round-trip via map-invert twice should equal original.
got2="$("$BIN" -e '(clojure.set/map-invert (clojure.set/map-invert (hash-map :a 1 :b 2)))')"
assert_eq 'map_invert_round_trip' "$got2" '{:a 1, :b 2}'

got="$("$BIN" -e '(clojure.set/map-invert (hash-map))')"
assert_eq 'map_invert_empty' "$got" '{}'

# Sanity-check the inverted key lookups via re-invert.
got="$("$BIN" -e '(clojure.set/map-invert (hash-map :x :y))')"
assert_eq 'map_invert_keyword_pair' "$got" '{:y :x}'

echo "phase6_clojure_set_cycle2: all 9 cases passed"
