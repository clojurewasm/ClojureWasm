#!/usr/bin/env bash
# test/e2e/phase7_instance_q.sh
#
# `instance?` — ADR-0128 (D-373): now a clj FN over a class VALUE
# (`(def instance? (fn* [c x] (rt/-instance-of? c x)))`), NOT a macro. The class
# symbol evaluates to a class value via the analyzer's class-value arm, so
# `instance?` is passable higher-order (condp / map / partial — Case 8). The
# `-instance-of?` primitive consults `runtime/class_name.zig::isInstance`, the
# complete membership oracle:
#   - host_class.matches for Throwable hierarchy queries
#   - native exact-tag table (String / Long / Pattern / ...)
#   - interface multi-tag sets (IFn / Number / IPersistent*)
#   - Object universal arm (every non-nil value); opaque → false naturally
#   - TypeDescriptor.parent walk for typed_instance / reified_instance
#
# An unknown class symbol now errors at ANALYSIS (`Unable to resolve symbol`) —
# the class arg evaluates, so an unresolvable class is a compile-time error
# (closer to clj than the old macro-path `class_name_unknown`).

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
(prn (instance? Throwable (ex-info "x" {})))
EOF
)
assert_eq 'throwable_ex_info' "$got" 'true'

got=$("$BIN" -e '(instance? Throwable nil)' 2>/dev/null)
assert_eq 'throwable_nil_false' "$got" 'false'

got=$("$BIN" -e '(instance? Throwable 42)' 2>/dev/null)
assert_eq 'throwable_int_false' "$got" 'false'

# --- Case 5: Exception via parent walk ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (instance? Exception (ex-info "x" {})))
EOF
)
assert_eq 'exception_parent_walk' "$got" 'true'

# --- Case 6: FQCN normalises ---
got=$("$BIN" -e '(instance? java.lang.Long 42)' 2>/dev/null)
assert_eq 'fqcn_long' "$got" 'true'

# --- Case 7: Unknown class errors at analysis (the class arg evaluates, so an
# unresolvable class symbol is a compile-time unresolved-symbol error — ADR-0128). ---
diag=$("$BIN" -e '(instance? NoSuchClassXyz 42)' 2>&1 || true)
case "$diag" in
    *"Unable to resolve symbol: 'NoSuchClassXyz'"*)
        echo "PASS unknown_class_raises -> diagnostic" ;;
    *)
        fail "unknown_class_raises: missing diagnostic ($diag)" ;;
esac

# --- Case 8: higher-order instance? (the D-373 fix — a macro could not do this) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (condp instance? "x" Number :n String :s :o))
EOF
)
assert_eq 'condp_instance' "$got" ':s'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (mapv (partial instance? Number) [1 :a 2.0 "x"]))
EOF
)
assert_eq 'partial_instance_map' "$got" '[true false true false]'

# interface marker resolves as a class value + matches (was a NameError pre-ADR-0128)
got=$("$BIN" -e '(instance? clojure.lang.IPersistentVector [1 2])' 2>/dev/null)
assert_eq 'interface_marker_value' "$got" 'true'

# class symbol passed as a plain fn arg (higher-order), bound then applied
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn ((fn [c v] (instance? c v)) Long 42))
EOF
)
assert_eq 'class_as_fn_arg' "$got" 'true'

# --- Case 9: bare IMPORTED class name as the class arg (the flatland.ordered.map
# scenario: `(:import (java.util Map$Entry))` then bare `Map$Entry`). The analyzer
# resolves the import to the FQCN, then to the native MapEntry class value. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(ns t (:import (java.util Map$Entry)))
(prn (instance? Map$Entry (first {:a 1})))
EOF
)
assert_eq 'imported_map_entry' "$got" 'true'

echo
echo "Phase 7 instance? (ADR-0128 fn over class value) e2e: all green."
