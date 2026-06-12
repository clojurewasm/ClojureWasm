#!/usr/bin/env bash
# test/e2e/phase7_record_field_scope.sh
#
# D-202(1) — defrecord/deftype bring their declared fields into scope as
# implicit locals inside protocol method bodies, matching Clojure. So
# `(defrecord R [v] P (m [this] (* v 2)))` resolves the bare `v` without an
# explicit `(:v this)` / `(.v this)`. Lowering wraps each method body with a
# field `let*` over `(.<field> <instance>)`, excluding fields shadowed by a
# method param (clj semantics: the param wins — verified against the oracle).
#
# Both backends must agree (the let* lowers to existing let*+dot-access).
# Verified via e2e top-level forms, NOT the clj_diff batch sweep (which wraps
# each line in (prn …) and so cannot host top-level defrecord/defprotocol).

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

# --- Case 1: defrecord bare field ref in a method body ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [this]))
(defrecord R [v] P (m [this] (* v 2)))
(prn (m (->R 5)))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defrecord_bare_field' "$(last_line "$got")" '10'

# --- Case 2: deftype bare field ref (not keyword-accessible — dot-access path) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [this]))
(deftype T [v] P (m [this] (* v 3)))
(prn (m (->T 4)))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'deftype_bare_field' "$(last_line "$got")" '12'

# --- Case 3: a method param shadows the field of the same name (param wins) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [this v]))
(defrecord R [v] P (m [this v] v))
(prn (m (->R 1) 99))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'param_shadows_field' "$(last_line "$got")" '99'

# --- Case 4: an un-shadowed field is visible alongside a method param ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [this x]))
(defrecord R [v] P (m [this x] (+ v x)))
(prn (m (->R 10) 5))
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'unshadowed_field_with_param' "$(last_line "$got")" '15'

# --- Case 5: multiple fields, multiple methods, all bare ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IPt (sx [t]) (sy [t]) (sm [t]))
(defrecord Pt [a b] IPt (sx [_] a) (sy [_] b) (sm [_] (+ a b)))
(prn [(sx (->Pt 3 4)) (sy (->Pt 3 4)) (sm (->Pt 3 4))])
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'multi_field_bare' "$(last_line "$got")" '[3 4 7]'

# --- Case 6: instance param named `_`, bare field still resolves ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [this]))
(deftype T [v] P (m [_] (inc v)))
(prn (m (->T 41)))
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'discard_instance_bare_field' "$(last_line "$got")" '42'

# --- Case 7: explicit (:field this) keeps working beside the bare alias ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol Shape (area [s]))
(defrecord Sq [side] Shape (area [s] (* (:side s) side)))
(prn (area (->Sq 6)))
EOF
) || fail "case7: non-zero exit ($got)"
assert_eq 'explicit_and_bare_mix' "$(last_line "$got")" '36'

# --- Case 8: both backends agree (dual-backend parity) ---
got=$("$BIN" --compare - <<'EOF' 2>/dev/null
(defprotocol P (m [this]))
(defrecord R [v] P (m [this] (* v v)))
(m (->R 7))
EOF
) || fail "case8: non-zero exit ($got)"
assert_eq 'backend_parity' "$(last_line "$got")" 'OK 49'

echo "OK — phase7_record_field_scope (8 cases) green"
