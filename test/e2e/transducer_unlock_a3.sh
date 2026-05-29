#!/usr/bin/env bash
# test/e2e/transducer_unlock_a3.sh
#
# Phase 6.16.a-3.2 EXIT smoke — eager higher-order surface
# (map / filter / take / drop / keep / remove + partial / comp /
# complement / constantly / juxt) per ADR-0033 D6 + v5 §5.2.
#
# **Note**: file named `transducer_unlock_a3.sh` per v5 §9.2 schedule
# (transducer 先取り cycle), but transducer 1-arg arity is **deferred**
# to a future cycle that lands multi-arity `fn*` (D-NEW-2). This cycle
# ships eager-only surface; the file name is preserved to keep the
# v5 deliverable-name commitment.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

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

# --- map ---
assert_eq 'map_inc'         "$("$BIN" -e '(map inc [1 2 3])')"        '(2 3 4)'
assert_eq 'map_empty'       "$("$BIN" -e '(map inc [])')"             'nil'

# --- filter ---
assert_eq 'filter_pos'      "$("$BIN" -e '(filter pos? [-1 2 -3 4])')" '(2 4)'
assert_eq 'filter_none'     "$("$BIN" -e '(filter pos? [-1 -2])')"     'nil'

# --- take ---
assert_eq 'take_n'          "$("$BIN" -e '(take 2 [1 2 3 4 5])')"     '(1 2)'
assert_eq 'take_zero'       "$("$BIN" -e '(take 0 [1 2])')"            'nil'
assert_eq 'take_more'       "$("$BIN" -e '(take 99 [1 2])')"           '(1 2)'

# --- drop ---
assert_eq 'drop_n'          "$("$BIN" -e '(drop 2 [1 2 3 4 5])')"     '(3 4 5)'
assert_eq 'drop_all'        "$("$BIN" -e '(drop 99 [1 2])')"           'nil'

# --- keep ---
assert_eq 'keep_pos'        "$("$BIN" -e '(keep (fn* [x] (if (pos? x) x nil)) [-1 2 -3 4])')" '(2 4)'

# --- remove ---
assert_eq 'remove_pos'      "$("$BIN" -e '(remove pos? [-1 2 -3 4])')" '(-1 -3)'

# --- constantly ---
assert_eq 'constantly_no_args'  "$("$BIN" -e '((constantly 42))')"        '42'
assert_eq 'constantly_many_args' "$("$BIN" -e '((constantly 42) 1 2 3)')"  '42'

# --- complement ---
assert_eq 'complement_neg'  "$("$BIN" -e '((complement pos?) -1)')"  'true'
assert_eq 'complement_pos'  "$("$BIN" -e '((complement pos?) 1)')"    'false'

# --- partial ---
assert_eq 'partial_1arg'    "$("$BIN" -e '((partial + 10) 5)')"            '15'
assert_eq 'partial_2args'   "$("$BIN" -e '((partial + 10 20) 3 4)')"        '37'

# --- comp ---
assert_eq 'comp_2_fns'      "$("$BIN" -e '((comp inc inc) 5)')"            '7'

# --- juxt ---
assert_eq 'juxt_2_fns'      "$("$BIN" -e '((juxt inc dec) 5)')"            '[6 4]'

# --- compositional sanity ---
assert_eq 'count_of_map'    "$("$BIN" -e '(count (map inc [1 2 3]))')"        '3'
assert_eq 'reduce_filter'   "$("$BIN" -e '(reduce + 0 (filter pos? [-1 1 -2 2 -3 3]))')" '6'
assert_eq 'comp_in_map'     "$("$BIN" -e '(map (comp inc inc) [1 2 3])')"     '(3 4 5)'

echo ""
echo "=== transducer_unlock_a3: all assertions passed (eager-only; transducer arity deferred D-NEW-2) ==="
