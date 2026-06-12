#!/usr/bin/env bash
# test/e2e/phase14_math.sh
#
# §A26 interop coverage Q1 — java.lang.Math static dispatch + the
# java.lang auto-import resolution path (ADR-0050 R3 follow-up).
#
# Validates:
#   - bare (Math/abs …) resolves via the cljw.java.lang.<head> auto-import
#     (today fails "No namespace: 'Math'")
#   - F-005 type preservation: (Math/abs -5) → Integer 5, (Math/abs -5.0)
#     → Float 5.0 (NOT widened); min/max likewise
#   - sqrt/floor/ceil/pow always Float; round → Integer
#   - bonus: bare (System/…) now also resolves via the auto-import
#
# Static dispatch is TreeWalk-only at v0.1.0 (the .static_method VM arm
# is VM-DEFER, D-130); this runs on the default (tree-walk) backend.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

# --- abs: type-preserving (F-005) ---
assert_eq 'abs_int'        "$("$BIN" -e '(Math/abs -5)')"            '5'
assert_eq 'abs_int_type'   "$("$BIN" -e '(integer? (Math/abs -5))')" 'true'
# Value via `=` (cljw prints whole-valued floats without the `.0`, a
# pre-existing printer divergence from JVM Clojure — orthogonal to Math).
assert_eq 'abs_float'      "$("$BIN" -e '(= 5.0 (Math/abs -5.0))')"  'true'
assert_eq 'abs_float_type' "$("$BIN" -e '(float? (Math/abs -5.0))')" 'true'

# --- min / max: type-preserving ---
assert_eq 'max_int'  "$("$BIN" -e '(Math/max 3 7)')" '7'
assert_eq 'min_int'  "$("$BIN" -e '(Math/min 3 7)')" '3'
assert_eq 'max_type' "$("$BIN" -e '(integer? (Math/max 3 7))')" 'true'

# --- always-Float: sqrt / floor / ceil / pow ---
assert_eq 'sqrt'  "$("$BIN" -e '(= 2.0 (Math/sqrt 4))')"   'true'
assert_eq 'floor' "$("$BIN" -e '(= 2.0 (Math/floor 2.7))')" 'true'
assert_eq 'ceil'  "$("$BIN" -e '(= 3.0 (Math/ceil 2.1))')"  'true'
assert_eq 'pow'   "$("$BIN" -e '(= 1024.0 (Math/pow 2 10))')" 'true'

# --- round → Integer ---
assert_eq 'round'      "$("$BIN" -e '(Math/round 2.6)')"            '3'
assert_eq 'round_type' "$("$BIN" -e '(integer? (Math/round 2.6))')" 'true'

# --- bonus: bare (System/…) resolves via the same java.lang auto-import ---
assert_eq 'system_auto_import' "$("$BIN" -e '(> (System/currentTimeMillis) 0)')" 'true'

echo "OK — phase14_math smoke (15 cases) green"
