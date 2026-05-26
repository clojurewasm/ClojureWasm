#!/usr/bin/env bash
# test/e2e/phase7_defrecord.sh
#
# Phase 7 §9.9 row 7.4 cycle 1 — defrecord macro skeleton smoke.
# Validates the cycle-1 surface:
#   - `(defrecord Foo [x y])` parses cleanly (no STAGED_UNSUPPORTED_FORMS
#     raise; row 7.4 cycle 1 retired the wedge).
#   - Lowering via `expandDefrecord` produces `(do (deftype Foo [x y]))`,
#     so the underlying TypeDescriptor allocates with `.kind = .deftype`
#     today. Cycle 2 will flip `.kind = .defrecord` via the
#     `rt/__defrecord!` primitive.
#   - Constructor + field access still work (inherited from the
#     deftype skeleton landed at Phase 5 task 5.12.a).
#
# OUT OF SCOPE for cycle 1: `(:field rec)` implicit IPersistentMap
# routing (cycle 3), `(assoc rec :k v)` (cycle 4), `->Foo` positional
# factory + protocol-method bodies (cycle 5), `record?` predicate
# (cycle 6).
#
# stderr captured for diagnostic cases only.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

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

# --- Case 1: defrecord parses cleanly + ctor + field access ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(.x (Point. 3 4))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defrecord_ctor_field_access' "$(last_line "$got")" '3'

# --- Case 2: defrecord field y access ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(.y (Point. 3 4))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'defrecord_field_y_access' "$(last_line "$got")" '4'

# --- Case 3: defrecord with no field vector raises defrecord_form_incomplete ---
diag=$("$BIN" -e '(defrecord Foo)' 2>&1 || true)
if [[ "$diag" != *"defrecord requires"* ]]; then
    fail "case3: expected defrecord_form_incomplete, got '$diag'"
fi
echo "PASS defrecord_form_incomplete_diagnostic"

# --- Case 4: defrecord with non-symbol name raises defrecord_name_invalid ---
diag=$("$BIN" -e '(defrecord "Foo" [x])' 2>&1 || true)
if [[ "$diag" != *"defrecord name"* ]]; then
    fail "case4: expected defrecord_name_invalid, got '$diag'"
fi
echo "PASS defrecord_name_invalid_diagnostic"

# --- Case 5: defrecord with non-vector fields raises defrecord_fields_not_vector ---
diag=$("$BIN" -e '(defrecord Foo "x")' 2>&1 || true)
if [[ "$diag" != *"defrecord fields"* ]]; then
    fail "case5: expected defrecord_fields_not_vector, got '$diag'"
fi
echo "PASS defrecord_fields_not_vector_diagnostic"

# --- Case 6 (cycle 3): implicit get on declared field ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(get (Point. 3 4) :x)
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'defrecord_get_declared_field' "$(last_line "$got")" '3'

# --- Case 7 (cycle 3): get with default + multiple values via let* ---
# Note: `(:k coll)` keyword-as-fn callable is intentionally deferred
# to a future cycle — `tree_walk.callFn` lacks a `.keyword` arm and
# adding it cleanly requires a Layer-0 lookup helper (eval/ cannot
# import lang/primitive/collection.zig). Tracked via D-085 in debt.md.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(let* [p (Point. 3 4)] (+ (get p :x) (get p :y)))
EOF
) || fail "case7: non-zero exit ($got)"
assert_eq 'defrecord_get_sum_two_fields' "$(last_line "$got")" '7'

# --- Case 8 (cycle 3): get on undeclared key returns nil ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(get (Point. 3 4) :z)
EOF
) || fail "case8: non-zero exit ($got)"
assert_eq 'defrecord_get_undeclared_returns_nil' "$(last_line "$got")" 'nil'

# --- Case 9 (cycle 3): get with default on undeclared key ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(get (Point. 3 4) :z 99)
EOF
) || fail "case9: non-zero exit ($got)"
assert_eq 'defrecord_get_undeclared_default' "$(last_line "$got")" '99'

# --- Case 10 (cycle 3): count returns field count ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(count (Point. 3 4))
EOF
) || fail "case10: non-zero exit ($got)"
assert_eq 'defrecord_count_field_count' "$(last_line "$got")" '2'

# --- Case 12 (cycle 4): assoc on declared key returns updated record ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(get (assoc (Point. 3 4) :x 99) :x)
EOF
) || fail "case12: non-zero exit ($got)"
assert_eq 'defrecord_assoc_declared_field' "$(last_line "$got")" '99'

# --- Case 13 (cycle 4): assoc preserves other fields ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(get (assoc (Point. 3 4) :x 99) :y)
EOF
) || fail "case13: non-zero exit ($got)"
assert_eq 'defrecord_assoc_preserves_other_field' "$(last_line "$got")" '4'

# --- Case 14 (cycle 4): assoc on non-declared key raises PROVISIONAL ---
# D-086: __extmap overflow is deferred — non-declared key assoc raises
# feature_not_supported until the layout migration lands.
diag=$("$BIN" -e '(defrecord Point [x y]) (assoc (Point. 3 4) :z 99)' 2>&1 || true)
if [[ "$diag" != *"defrecord"* ]] || [[ "$diag" != *"non-declared"* ]]; then
    fail "case14: expected defrecord non-declared-key diagnostic, got '$diag'"
fi
echo "PASS defrecord_assoc_undeclared_provisional"

# --- Case 15 (cycle 4): keys returns the declared field names ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(count (keys (Point. 3 4)))
EOF
) || fail "case15: non-zero exit ($got)"
assert_eq 'defrecord_keys_count' "$(last_line "$got")" '2'

# --- Case 16 (cycle 4): vals returns the declared values ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(count (vals (Point. 3 4)))
EOF
) || fail "case16: non-zero exit ($got)"
assert_eq 'defrecord_vals_count' "$(last_line "$got")" '2'

# --- Case 11 (cycle 3): deftype does NOT route through IPersistentMap ---
# `(get deftype-inst :x)` returns nil — deftype is not a map. defrecord
# is the only TypedInstance whose `descriptor.kind` enables the
# implicit map routing in `getFn`.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Pair [a b])
(get (Pair. 1 2) :a)
EOF
) || fail "case11: non-zero exit ($got)"
assert_eq 'deftype_get_no_map_routing_returns_nil' "$(last_line "$got")" 'nil'

# --- Case 17 (cycle 5): ->Name positional factory ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(get (->Point 7 8) :x)
EOF
) || fail "case17: non-zero exit ($got)"
assert_eq 'defrecord_arrow_factory' "$(last_line "$got")" '7'

# --- Case 18 (cycle 5): protocol-method body inline in defrecord ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IPos (pos-sum [p]))
(defrecord Point [x y]
  IPos (pos-sum [this] (+ (get this :x) (get this :y))))
(pos-sum (->Point 10 20))
EOF
) || fail "case18: non-zero exit ($got)"
assert_eq 'defrecord_inline_protocol_body' "$(last_line "$got")" '30'

echo "OK — phase7_defrecord smoke (18 cases) green"
