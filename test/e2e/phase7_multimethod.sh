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
(area {:type :circle})
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defmulti_circle' "$(last_line "$got")" ':pi'

# --- Case 2: dispatch on :square (second defmethod) ---
got=$("$BIN" - <<'EOF' 2>&1
(defmulti area (fn* [s] (get s :type)))
(defmethod area :circle [_] :pi)
(defmethod area :square [_] :sq)
(area {:type :square})
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'defmulti_square' "$(last_line "$got")" ':sq'

# --- Case 3: default fallback when no method matches ---
got=$("$BIN" - <<'EOF' 2>&1
(defmulti g (fn* [s] (get s :k)))
(defmethod g :a [_] :a-result)
(defmethod g :default [_] :fallback)
(g {:k :missing})
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
(h {:k :x})
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'prefer_method_compiles' "$(last_line "$got")" ':x-result'

# --- Case 5: defmethod body can reference its parameter ---
got=$("$BIN" - <<'EOF' 2>&1
(defmulti describe (fn* [s] (get s :k)))
(defmethod describe :n [s] (get s :v))
(describe {:k :n :v 42})
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'defmethod_body_uses_param' "$(last_line "$got")" '42'

echo "OK — phase7_multimethod ladder (5 cases) green"
