#!/usr/bin/env bash
# test/e2e/phase14_print_method.sh
#
# D-370 / ADR-0127 — `print-method` user-extensible print multimethod. The native
# pr/prn/print/pr-str path consults `print-method` behind an any-override dirty flag;
# `(defmethod print-method T [o w] …)` customises T's printing, including nested in a
# native collection (ADR-0127 B2 per-element consult). Validates:
#   - a direct override fires on pr / pr-str;
#   - the no-override case is byte-identical to the native render (zero regression);
#   - a user method recursing `(print-method child w)` lands on the native default;
#   - B2(b-ii): an override-typed value NESTED in a native vector / map renders via
#     the override (clj per-element recursion parity);
#   - the writer handle works inside with-out-str (the active sink is wrapped).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

# --- Case 1: direct override on pr-str ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Pt [x y])
(defmethod print-method Pt [o w] (.write w "#PT"))
(print (pr-str (Pt. 1 2)))
EOF
) || fail "case1: non-zero exit ($got)"
[ "$got" = "#PT" ] || fail "case1: expected #PT, got '$got'"

# --- Case 2: no override = native unchanged ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(print (pr-str [1 2 3] {:a 1} "hi" :kw))
EOF
) || fail "case2: non-zero exit ($got)"
[ "$got" = '[1 2 3] {:a 1} "hi" :kw' ] || fail "case2: expected native render, got '$got'"

# --- Case 3: user method recurses (print-method child w) → native default ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Box [v])
(defmethod print-method Box [o w] (.write w "Box<") (print-method (.-v o) w) (.write w ">"))
(print (pr-str (Box. 42)))
EOF
) || fail "case3: non-zero exit ($got)"
[ "$got" = "Box<42>" ] || fail "case3: expected Box<42>, got '$got'"

# --- Case 4: B2(b-ii) — override nested in a native vector AND map value ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Pt [x y])
(defmethod print-method Pt [o w] (.write w "#PT"))
(print (pr-str [(Pt. 1 2) 9 {:k (Pt. 3 4)}]))
EOF
) || fail "case4: non-zero exit ($got)"
[ "$got" = "[#PT 9 {:k #PT}]" ] || fail "case4: expected [#PT 9 {:k #PT}], got '$got'"

# --- Case 5: override fires inside with-out-str (active sink wrapped) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Pt [x])
(defmethod print-method Pt [o w] (.write w "#PT"))
(print (with-out-str (pr (Pt. 1))))
EOF
) || fail "case5: non-zero exit ($got)"
[ "$got" = "#PT" ] || fail "case5: expected #PT, got '$got'"

echo "PASS phase14_print_method (5 cases)"
