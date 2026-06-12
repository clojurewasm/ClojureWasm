#!/usr/bin/env bash
# test/e2e/phase7_polymorphic_extend.sh
#
# Phase 7 §9.9 row 7.7 cycle 1 — hybrid polymorphic primitives.
# Wires `count` from a Tag-switch hardcode into a hybrid:
#   - Existing fast-path arms (.string / .list / .vector / .array_map /
#     .hash_map / .hash_set / .chunked_cons / .lazy_seq) stay verbatim.
#   - `.typed_instance` arm consults method_table for
#     `clojure.core/IPersistentCollection -count` first (R3a per
#     ADR-0008 amendment 4); falls back to field_count for defrecord
#     without an override (preserves row 7.4 cycle 3 semantics).
#   - Outer else => routes through `dispatch(...)` against
#     `clojure.core/IPersistentCollection -count`, reaching
#     `(extend-type LongTag …)`-style native-Tag overrides via the
#     row 7.3 per-Tag descriptor registry.
#
# Bootstrap: `clojure.core/IPersistentCollection` defprotocol form
# lives in `src/lang/clj/clojure/core.clj` so the fqcn the slow-path
# matches is stable across cycles.
#
# OUT OF SCOPE for cycle 1: `deftype` name binding (deftype does not
# def the name as a Var today; extend-type on a deftype target
# requires a follow-up debt row).

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

last_line() {
    awk 'END { print }' <<< "$1"
}

# --- Case 1: defrecord WITH explicit -count override wins over field_count ---
# R3a: method_table consult for clojure.core/IPersistentCollection -count
# finds the user entry → user impl wins. Without R3a (= today), field_count
# would silently override.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(extend-type Point IPersistentCollection (-count [_] 99))
(prn (count (->Point 3 4)))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defrecord_count_user_override_wins' "$(last_line "$got")" '99'

# --- Case 2: defrecord without override still returns field_count ---
# R3a precedence: method_table consult finds no entry → field_count
# fallback wins. Preserves row 7.4 cycle 3 case10.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Plain [a b])
(prn (count (->Plain 3 4)))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'defrecord_count_field_count_preserved' "$(last_line "$got")" '2'

# --- Case 3: native Tag (Long) reaches count via outer-else slow-path ---
# (extend-type Long IPersistentCollection -count …) registers the entry
# on the per-Tag descriptor for .integer (row 7.3). The outer else of
# count routes through dispatch(…IPC, -count) and reaches the override.
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long IPersistentCollection (-count [n] 5))
(prn (count 42))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'long_count_via_outer_else_slow_path' "$(last_line "$got")" '5'

# --- Case 4: native Tag without extend-type raises protocol_no_satisfies ---
# Without the override, (count 42) reaches the outer-else slow-path
# which raises protocol_no_satisfies. The diagnostic supersedes the
# pre-row-7.7 type_arg_invalid raise (cleaner JVM-parity error name).
diag=$("$BIN" -e '(count 42)' 2>&1 || true)
if [[ "$diag" != *"satisfy"* ]] && [[ "$diag" != *"no method"* ]] && [[ "$diag" != *"IPersistentCollection"* ]]; then
    fail "case4: expected protocol_no_satisfies diagnostic, got '$diag'"
fi
echo "PASS long_count_no_extend_raises_diagnostic"

# --- Case 5 (cycle 2): defrecord reaches seq via Seqable extend-type ---
# seq has no .typed_instance fast-path; today defrecord falls into the
# outer else => raise. Row 7.7 cycle 2 rewires outer else through
# dispatch.dispatch(..., "Seqable", "-seq", ...) so user
# (extend-type Pair Seqable (-seq [_] …)) reaches seq.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Pair [a b])
(extend-type Pair Seqable (-seq [_] '(1 2)))
(prn (seq (->Pair 1 2)))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'defrecord_seq_via_extend_type' "$(last_line "$got")" '(1 2)'

# --- Case 6 (cycle 2): native Tag (Long) reaches seq via outer-else slow-path ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long Seqable (-seq [_] '(:a :b)))
(prn (seq 42))
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'long_seq_via_outer_else_slow_path' "$(last_line "$got")" '(:a :b)'

# --- Case 7 (cycle 2): non-seqable native Tag without extend raises ---
diag=$("$BIN" -e '(seq 42)' 2>&1 || true)
if [[ "$diag" != *"satisfy"* ]] && [[ "$diag" != *"Seqable"* ]] && [[ "$diag" != *"no method"* ]]; then
    fail "case7: expected protocol_no_satisfies diagnostic, got '$diag'"
fi
echo "PASS long_seq_no_extend_raises_diagnostic"

# --- Case 8 (cycle 3): defrecord reaches conj via IPersistentCollection -cons ---
# conj's outer else => raise becomes a route through dispatch against
# `IPersistentCollection -cons`. User (extend-type X IPersistentCollection
# (-cons [c x] ...)) installs the method; conj on the user receiver reaches it.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Bag [contents])
(extend-type Bag IPersistentCollection (-cons [_ x] x))
(prn (conj (->Bag '()) 99))
EOF
) || fail "case8: non-zero exit ($got)"
assert_eq 'defrecord_conj_via_extend_type' "$(last_line "$got")" '99'

# --- Case 9 (cycle 3): Long without extend-type IPersistentCollection raises ---
diag=$("$BIN" -e '(conj 42 1)' 2>&1 || true)
if [[ "$diag" != *"satisfy"* ]] && [[ "$diag" != *"IPersistentCollection"* ]] && [[ "$diag" != *"no method"* ]]; then
    fail "case9: expected protocol_no_satisfies diagnostic, got '$diag'"
fi
echo "PASS long_conj_no_extend_raises_diagnostic"

# --- Case 10 (cycle 4): defrecord reaches reduce via IReduce -reduce ---
# reduce's IReduce fast-path runs BEFORE the seq-walk. User impl wins
# without the receiver needing a Seqable -seq extension; argument order
# is receiver-first (Box, f) to match `(-reduce [c f] …)` user shape.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Box [v])
(extend-type Box IReduce (-reduce [_ _] 99))
(prn (reduce + (->Box 1)))
EOF
) || fail "case10: non-zero exit ($got)"
assert_eq 'defrecord_reduce_via_ireduce' "$(last_line "$got")" '99'

# --- Case 11 (cycle 4): reduce falls back to seq-walk when no IReduce ---
# Box has no IReduce extension but has Seqable. reduce should not raise
# on the IReduce slow-path miss; instead it walks the seq.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Pair2 [a b])
(extend-type Pair2 Seqable (-seq [_] '(10 20 30)))
(prn (reduce + 0 (->Pair2 1 2)))
EOF
) || fail "case11: non-zero exit ($got)"
assert_eq 'defrecord_reduce_fallback_to_seq_walk' "$(last_line "$got")" '60'
