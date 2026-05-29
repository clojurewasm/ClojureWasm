#!/usr/bin/env bash
# test/e2e/phase6_clojure_walk_cycle1.sh
#
# Phase 6.11 cycle 1 EXIT smoke — clojure.walk spine
# (walk + prewalk + postwalk).
#
# Per survey §8 cycle 1: Tag-dispatch over .list / .vector /
# .array_map / .hash_set with vtable callout for user fns
# (inner / outer). prewalk + postwalk are Zig-direct recursion
# (no `partial` dependency).

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

# --- walk (one-level) ---
# (walk inner outer form): apply inner to each immediate child,
# rebuild, then outer on the whole.

got="$("$BIN" -e '(clojure.walk/walk inc identity [1 2 3])')"
assert_eq 'walk_vector_inc' "$got" '[2 3 4]'

got="$("$BIN" -e '(clojure.walk/walk inc identity (hash-set 1 2))')"
# Order is hash-determined; check via difference (= empty).
got2="$("$BIN" -e '(clojure.set/difference (clojure.walk/walk inc identity (hash-set 1 2)) (hash-set 2 3))')"
assert_eq 'walk_set_inc' "$got2" '#{}'

# scalar pass-through (outer applied to scalar form).
got="$("$BIN" -e '(clojure.walk/walk inc dec 5)')"
assert_eq 'walk_scalar_outer_only' "$got" '4'

# --- postwalk (post-order, f applied after children) ---
# JVM contract: f is invoked on EVERY node including rebuilt
# collections. Tests use a guarded fn so collection nodes pass
# through.

INC_INTS='(fn* [x] (if (integer? x) (inc x) x))'

got="$("$BIN" -e "(clojure.walk/postwalk $INC_INTS [1 [2 3] 4])")"
assert_eq 'postwalk_nested_vector' "$got" '[2 [3 4] 5]'

got="$("$BIN" -e "(clojure.walk/postwalk $INC_INTS 7)")"
assert_eq 'postwalk_scalar' "$got" '8'

got="$("$BIN" -e "(clojure.walk/postwalk $INC_INTS [])")"
assert_eq 'postwalk_empty_vector' "$got" '[]'

# --- prewalk (pre-order, f applied before recursing into children) ---

got="$("$BIN" -e "(clojure.walk/prewalk $INC_INTS [1 [2 3] 4])")"
assert_eq 'prewalk_nested_vector' "$got" '[2 [3 4] 5]'

got="$("$BIN" -e "(clojure.walk/prewalk $INC_INTS 7)")"
assert_eq 'prewalk_scalar' "$got" '8'

# --- map walk via array_map ---

# clojure.core/integer? + inc are not yet registered; the rt
# versions are refer'd into user/ at boot so call them unqualified.
got="$("$BIN" -e "(clojure.walk/postwalk $INC_INTS (hash-map :a 1 :b 2))")"
assert_eq 'postwalk_map_values' "$got" '{:a 2, :b 3}'

echo "phase6_clojure_walk_cycle1: all 9 cases passed"
