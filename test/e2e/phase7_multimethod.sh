#!/usr/bin/env bash
# test/e2e/phase7_multimethod.sh
#
# Phase 7 §9.9 row 7.2 exit smoke — multimethod ladder.
# Validates defmulti / defmethod / prefer-method end-to-end:
#   - exact-match dispatch
#   - default fallback on missing dispatch_val
#   - direct hierarchy ancestors-map (via prefer scaffolding)
#
# Hierarchy walk via derive / global-hierarchy is OUT OF SCOPE
# for cycle 5c (defer to a follow-up cycle that lands Atom +
# swap! per ROADMAP §A future). The macros + primitives shipped
# in cycle 5b-c exercise the exact-match + default paths
# unconditionally; hierarchy walk + prefer require the IRef
# layer that lands later. multimethod.zig's Layer-1 tests cover
# the hierarchy + prefer machinery; this fixture covers the
# user-facing macro surface.

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

# Multi-form stdin: cljw prints every top-level form's result, so the
# final form's value is the last line of stdout. The helper extracts it.
last_line() {
    awk 'END { print }' <<< "$1"
}

# --- Case 1: defmulti + defmethod + dispatch on :circle ---
got=$("$BIN" - <<'EOF' 2>&1
(defmulti area (fn* [s] (get s :type)))
(defmethod area :circle [_] :pi)
(defmethod area :square [_] :sq)
(prn (area {:type :circle}))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defmulti_circle' "$(last_line "$got")" ':pi'

# --- Case 2: dispatch on :square (second defmethod) ---
got=$("$BIN" - <<'EOF' 2>&1
(defmulti area (fn* [s] (get s :type)))
(defmethod area :circle [_] :pi)
(defmethod area :square [_] :sq)
(prn (area {:type :square}))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'defmulti_square' "$(last_line "$got")" ':sq'

# --- Case 3: default fallback when no method matches ---
got=$("$BIN" - <<'EOF' 2>&1
(defmulti g (fn* [s] (get s :k)))
(defmethod g :a [_] :a-result)
(defmethod g :default [_] :fallback)
(prn (g {:k :missing}))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'defmulti_default_fallback' "$(last_line "$got")" ':fallback'

# --- Case 4: prefer-method primitive surface compiles + runs ---
# (Without hierarchy ancestors, prefer-method has nothing to
# disambiguate on this dispatch — but the macro must analyze +
# evaluate without error.)
got=$("$BIN" - <<'EOF' 2>&1
(defmulti h (fn* [s] (get s :k)))
(defmethod h :x [_] :x-result)
(defmethod h :y [_] :y-result)
(prefer-method h :x :y)
(prn (h {:k :x}))
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'prefer_method_compiles' "$(last_line "$got")" ':x-result'

# --- Case 5: defmethod body can reference its parameter ---
got=$("$BIN" - <<'EOF' 2>&1
(defmulti describe (fn* [s] (get s :k)))
(defmethod describe :n [s] (get s :v))
(prn (describe {:k :n :v 42}))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'defmethod_body_uses_param' "$(last_line "$got")" '42'

# --- Case 6 (D-184): re-evaluating defmulti is a defonce-style no-op —
# the existing MultiFn (with its registered defmethods) survives, so a
# namespace reload keeps the methods. Enabled by the ADR-0038 amendment
# (analyzeDef no longer resets the Var's root at analyze time). ---
got=$("$BIN" - <<'EOF' 2>&1
(defmulti area :shape)
(defmethod area :circle [_] :circ)
(defmulti area :shape)
(prn (area {:shape :circle}))
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'defmulti_reeval_noop' "$(last_line "$got")" ':circ'

# --- Case 7 (D-202 gap 3): `(defmulti name dispatch :default <val>)` overrides
# the no-match dispatch value (clj parity — was hardcoded `:default`). An
# unmatched dispatch routes to the method registered under <val>. ---
assert_eq 'defmulti_default_option' \
  "$("$BIN" -e '(do (defmulti k :t :default :other) (defmethod k :other [_] :fb) (k {:t :unknown}))')" \
  ':fb'

echo "OK — phase7_multimethod ladder (7 cases) green"
