#!/usr/bin/env bash
# test/e2e/phase7_instance_q.sh
#
# Phase 7 §9.9 row 7.12 cycle 1 — `instance?` macro + `__instance?`
# Layer-2 primitive landing (D-078 prep). The macro auto-quotes the
# Class symbol (`(instance? String x)` → `(__instance? (quote String) x)`)
# so user-form matches JVM syntax. Primitive consults
# `runtime/class_name.zig::isInstance` which routes through:
#   - host_class.matches for Throwable hierarchy queries
#   - native exact-tag table (String / Long / Pattern / ...)
#   - interface multi-tag sets (IFn / Number / IPersistent*)
#   - TypeDescriptor.parent walk for typed_instance / reified_instance
#
# Unknown class symbols raise loud `class_name_unknown` (no silent
# false — F-002 + permanent-no-op-forbidden per provisional_marker.md).

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

# --- Case 1: native exact tag ---
got=$("$BIN" -e '(instance? String "abc")' 2>/dev/null)
assert_eq 'native_string' "$got" 'true'

got=$("$BIN" -e '(instance? Long 42)' 2>/dev/null)
assert_eq 'native_long' "$got" 'true'

got=$("$BIN" -e '(instance? String 42)' 2>/dev/null)
assert_eq 'native_mismatch' "$got" 'false'

# --- Case 2: Number interface (integer + float) ---
got=$("$BIN" -e '(instance? Number 42)' 2>/dev/null)
assert_eq 'number_integer' "$got" 'true'

got=$("$BIN" -e '(instance? Number 3.14)' 2>/dev/null)
assert_eq 'number_float' "$got" 'true'

# --- Case 3: IFn interface ---
got=$("$BIN" -e '(instance? IFn (fn* [x] x))' 2>/dev/null)
assert_eq 'ifn_fn_val' "$got" 'true'

# --- Case 4: Throwable matches ex-info but NOT non-throwable ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(instance? Throwable (ex-info "x" {}))
EOF
)
assert_eq 'throwable_ex_info' "$got" 'true'

got=$("$BIN" -e '(instance? Throwable nil)' 2>/dev/null)
assert_eq 'throwable_nil_false' "$got" 'false'

got=$("$BIN" -e '(instance? Throwable 42)' 2>/dev/null)
assert_eq 'throwable_int_false' "$got" 'false'

# --- Case 5: Exception via parent walk ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(instance? Exception (ex-info "x" {}))
EOF
)
assert_eq 'exception_parent_walk' "$got" 'true'

# --- Case 6: FQCN normalises ---
got=$("$BIN" -e '(instance? java.lang.Long 42)' 2>/dev/null)
assert_eq 'fqcn_long' "$got" 'true'

# --- Case 7: Unknown class raises loud (no silent false) ---
diag=$("$BIN" -e '(instance? PersistentQueue 42)' 2>&1 || true)
case "$diag" in
    *"class 'PersistentQueue' is not a known class name"*)
        echo "PASS unknown_class_raises -> diagnostic" ;;
    *)
        fail "unknown_class_raises: missing diagnostic ($diag)" ;;
esac

echo
echo "Phase 7 row 7.12 cycle 1 instance? e2e: all green."
