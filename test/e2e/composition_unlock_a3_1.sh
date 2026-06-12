#!/usr/bin/env bash
# test/e2e/composition_unlock_a3_1.sh
#
# Phase 6.16.a-3.1 EXIT smoke — higher-order eager core
# (apply / reduce / into / every? / some / some?) per ADR-0033 D6
# + v5 §5.2. Builds on 6.16.a-1 fundamentals + 6.16.a-2 collection ops.
#
# Phase 6.16.a-3.2 adds the eager leaves + Layer 3 .clj defn
# (map/filter/take/drop/keep/remove + partial/comp/complement/constantly/juxt)
# and the full transducer e2e (`transducer_unlock_a3.sh`).
#
# Includes a Layer-2 sanity check for the has_rest fix on tree_walk
# (was a Phase-2 stub returning nil before Phase 6.16.a-3.1).

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

# --- has_rest stub fix ---
assert_eq 'has_rest_basic'   "$("$BIN" -e '((fn* [& xs] xs) 1 2 3)')"           '(1 2 3)'
assert_eq 'has_rest_mixed'   "$("$BIN" -e '((fn* [a & xs] [a xs]) 10 20 30)')" '[10 (20 30)]'
assert_eq 'has_rest_empty'   "$("$BIN" -e '((fn* [& xs] (count xs)))')"        '0'

# --- apply ---
assert_eq 'apply_seq'        "$("$BIN" -e '(apply + [1 2 3 4])')"              '10'
assert_eq 'apply_lead_seq'   "$("$BIN" -e '(apply + 1 2 [3 4])')"              '10'
assert_eq 'apply_nil_tail'   "$("$BIN" -e '(apply + nil)')"                    '0'

# --- reduce ---
assert_eq 'reduce_init'      "$("$BIN" -e '(reduce + 0 [1 2 3 4])')"           '10'
assert_eq 'reduce_no_init'   "$("$BIN" -e '(reduce + [1 2 3 4])')"             '10'
assert_eq 'reduce_empty'     "$("$BIN" -e '(reduce + [])')"                    '0'
# Reduced early termination via user lambda checking accumulator.
assert_eq 'reduce_early'     "$("$BIN" -e '(reduce (fn* [acc x] (if (> acc 5) acc (+ acc x))) 0 [1 2 3 4 5 6])')" '6'

# --- into ---
assert_eq 'into_vec_from_vec' "$("$BIN" -e '(into [] [1 2 3])')"               '[1 2 3]'
assert_eq 'into_set_from_vec' "$("$BIN" -e '(into (hash-set) [1 2 3])')"       '#{1 2 3}'
assert_eq 'into_map_kv_pairs' "$("$BIN" -e '(into (hash-map) [[:a 1] [:b 2]])')" '{:a 1, :b 2}'

# --- every? ---
assert_eq 'every_true'       "$("$BIN" -e '(every? pos? [1 2 3])')"            'true'
assert_eq 'every_false'      "$("$BIN" -e '(every? pos? [1 -1 3])')"           'false'
assert_eq 'every_empty_true' "$("$BIN" -e '(every? pos? [])')"                 'true'

# --- some ---
assert_eq 'some_finds'       "$("$BIN" -e '(some pos? [-1 -2 3])')"            'true'
assert_eq 'some_none'        "$("$BIN" -e '(some pos? [-1 -2 -3])')"           'nil'
# --- not-every? (sibling of not-any?) ---
assert_eq 'not_every_t'      "$("$BIN" -e '(not-every? even? [2 4 5])')"       'true'
assert_eq 'not_every_f'      "$("$BIN" -e '(not-every? even? [2 4 6])')"       'false'

# --- some? ---
assert_eq 'some_q_nil'       "$("$BIN" -e '(some? nil)')"                      'false'
assert_eq 'some_q_zero'      "$("$BIN" -e '(some? 0)')"                        'true'
assert_eq 'some_q_false'     "$("$BIN" -e '(some? false)')"                    'true'

# --- composition with a-1 + a-2 primitives ---
assert_eq 'reduce_conj_set'  "$("$BIN" -e '(reduce conj (hash-set) [1 2 3])')" '#{1 2 3}'
assert_eq 'count_apply'      "$("$BIN" -e '(count (apply (fn* [& xs] xs) [1 2 3 4]))')" '4'

echo ""
echo "=== composition_unlock_a3_1: all assertions passed ==="
