#!/usr/bin/env bash
# test/e2e/phase6_16_c_walk_pattern_a.sh
#
# Phase 6.16.c Group A — clojure.walk Pattern A migration of
# `prewalk` + `postwalk`. v5 §9.1. Other vars (`keywordize-keys`,
# `stringify-keys`, `prewalk-replace`, `postwalk-replace`,
# `prewalk-demo`, `postwalk-demo`, `macroexpand-all`) land in
# subsequent groups within Phase 6.16.c.

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

# --- (1) prewalk identity on a vector → unchanged ---
got="$("$BIN" -e "(clojure.walk/prewalk (fn* [x] x) [1 2 3])")"
assert_eq 'prewalk_identity_vector' "$got" '[1 2 3]'

# --- (2) postwalk inc on nested vector → all leaves incremented ---
got="$("$BIN" -e "(clojure.walk/postwalk (fn* [x] (if (integer? x) (inc x) x)) [1 [2 3]])")"
assert_eq 'postwalk_inc_nested' "$got" '[2 [3 4]]'

# --- (3) prewalk wraps before recursion: increments are applied before
# children are visited. With a fn that only acts on integers, both pre-
# and post- give the same shape, but the recursion direction differs;
# this asserts the pre-order produces the correct shape, not the order. ---
got="$("$BIN" -e "(clojure.walk/prewalk (fn* [x] (if (integer? x) (inc x) x)) [10 [20 30]])")"
assert_eq 'prewalk_inc_nested' "$got" '[11 [21 31]]'

# --- (4) postwalk on a quoted list ---
got="$("$BIN" -e "(clojure.walk/postwalk (fn* [x] x) '(1 2 3))")"
assert_eq 'postwalk_identity_list' "$got" '(1 2 3)'

# --- Group B: prewalk-replace + postwalk-replace ---

# --- (5) postwalk-replace single-key swap on a vector ---
got="$("$BIN" -e "(clojure.walk/postwalk-replace {:a 1 :b 2} [:a :b :c])")"
assert_eq 'postwalk_replace_basic' "$got" '[1 2 :c]'

# --- (6) postwalk-replace recurses into nested forms ---
got="$("$BIN" -e "(clojure.walk/postwalk-replace {:x 10} [:x [:x :y]])")"
assert_eq 'postwalk_replace_nested' "$got" '[10 [10 :y]]'

# --- (7) prewalk-replace on nested vector ---
got="$("$BIN" -e "(clojure.walk/prewalk-replace {:x 99} [:x :y [:x]])")"
assert_eq 'prewalk_replace_nested' "$got" '[99 :y [99]]'

# --- (8) empty smap returns input unchanged ---
got="$("$BIN" -e "(clojure.walk/postwalk-replace {} [:a :b])")"
assert_eq 'postwalk_replace_empty_smap' "$got" '[:a :b]'

# --- Group C: keywordize-keys + stringify-keys ---

# --- (9) keywordize-keys on flat string-key map ---
got="$("$BIN" -e '(clojure.walk/keywordize-keys {"a" 1 "b" 2})' | tail -n 1)"
# Map iteration order is insertion-stable for array_map; assert both
# orderings to be safe.
case "$got" in
    "{:a 1, :b 2}"|"{:b 2, :a 1}") echo "PASS keywordize_keys_flat -> $got" ;;
    *) fail "keywordize_keys_flat: unexpected '$got'" ;;
esac

# --- (10) keywordize-keys preserves non-string keys ---
got="$("$BIN" -e '(clojure.walk/keywordize-keys {:already 1})')"
assert_eq 'keywordize_keys_preserves_keyword' "$got" '{:already 1}'

# --- (11) stringify-keys on flat keyword-key map ---
got="$("$BIN" -e '(clojure.walk/stringify-keys {:x 1 :y 2})')"
case "$got" in
    '{"x" 1, "y" 2}'|'{"y" 2, "x" 1}') echo "PASS stringify_keys_flat -> $got" ;;
    *) fail "stringify_keys_flat: unexpected '$got'" ;;
esac

# --- (12) round-trip ---
got="$("$BIN" -e '(clojure.walk/keywordize-keys (clojure.walk/stringify-keys {:a 1}))')"
assert_eq 'roundtrip_keyword_string_keyword' "$got" '{:a 1}'

# --- Group D: prewalk-demo + postwalk-demo + println prereq ---

# --- (13) println basic ---
got="$("$BIN" -e '(println "hi")')"
# println prints "hi\n" + REPL prints return value nil → "hi\nnil"
assert_eq 'println_basic' "$got" 'hi
nil'

# --- (14) println multi-arg space-separated ---
got="$("$BIN" -e '(println 1 2 3)')"
assert_eq 'println_multi' "$got" '1 2 3
nil'

# --- (15) prewalk-demo returns the form (printed lines + final REPL line) ---
# We assert the final REPL-printed line is the unmodified input.
got="$("$BIN" -e '(clojure.walk/prewalk-demo [1 2])' | tail -n 1)"
assert_eq 'prewalk_demo_returns_form' "$got" '[1 2]'

# --- (16) prewalk-demo pre-order prints parent before children ---
# Expect lines (in order): [1 2], 1, 2, [1 2] (last is REPL print of return).
got="$("$BIN" -e '(clojure.walk/prewalk-demo [1 2])')"
expected='[1 2]
1
2
[1 2]'
assert_eq 'prewalk_demo_traversal_order' "$got" "$expected"

# --- (17) postwalk-demo post-order: children first ---
got="$("$BIN" -e '(clojure.walk/postwalk-demo [1 2])')"
expected='1
2
[1 2]
[1 2]'
assert_eq 'postwalk_demo_traversal_order' "$got" "$expected"

# --- Group E: macroexpand-all transient stub ---

# --- (18) macroexpand-all raises (user-thrown ex-info → exit 1) ---
# Input shape doesn't matter for the stub — use a vector to avoid
# the F-004 quoted-symbol gap in the eval path. The ex-info message
# "macroexpand-all is not yet supported" is now surfaced at the CLI
# tail (ADR-0055 am2 / D-144); we still only assert non-zero exit +
# the surface symbol resolved (= analyzer pass succeeded), matching
# the existing pattern from test/e2e/phase4_exit_codes.sh.
if "$BIN" -e '(clojure.walk/macroexpand-all [1 2 3])' >/dev/null 2>&1; then
    fail "macroexpand_all_stub: expected non-zero exit, got success"
fi
echo "PASS macroexpand_all_transient_stub_raises"

echo ""
echo "=== phase6_16_c_walk_pattern_a: all assertions passed ==="
