#!/usr/bin/env bash
# test/e2e/phase14_catch_keyword.sh
#
# Phase 14 §9.16 row 14.5 — D-014b discharge. `(catch :type-keyword
# binding ...)` form: the analyzer accepts a keyword in the catch
# class slot; the TreeWalk dispatcher matches when the thrown
# ex-info's data map carries `:type <kw>` equal to the catch
# keyword.
#
# JVM Clojure has no native catch-by-keyword surface — the convention
# there is `(catch ExceptionInfo e (case (:type (ex-data e)) ...))`.
# cljw v1 elevates the keyword path to a 1st-class catch head so the
# Tier-A throw/catch story matches the cw-native ex-info shape.
#
# Layer 2 (e2e CLI) per ADR-0021. The VM backend rides a VM-DEFER
# marker per ADR-0036; the diff-test corpus stays TreeWalk-only for
# the keyword arm until the VM lowering ADR lands.

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

# --- Case 1: keyword catch matches when :type matches ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (throw (ex-info "boom" {:type :foo})) (catch :foo e :caught)))
EOF
)
assert_eq 'catch_keyword_type_match' "$got" ':caught'

# --- Case 2: keyword catch falls through when :type differs ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (throw (ex-info "boom" {:type :bar}))
  (catch :foo e :wrong)
  (catch ExceptionInfo e :fallback)))
EOF
)
assert_eq 'catch_keyword_type_mismatch_falls_through' "$got" ':fallback'

# --- Case 3: keyword catch falls through when data lacks :type ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (throw (ex-info "boom" {}))
  (catch :foo e :wrong)
  (catch ExceptionInfo e :fallback)))
EOF
)
assert_eq 'catch_keyword_no_type_key_falls_through' "$got" ':fallback'

# --- Case 4: keyword catch binds the thrown ex-info for body access ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (throw (ex-info "boom" {:type :foo})) (catch :foo e (ex-message e))))
EOF
)
assert_eq 'catch_keyword_binds_exception' "$got" '"boom"'

# --- Case 5: namespaced keyword (:my.app/error) matches by interned identity ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (throw (ex-info "boom" {:type :my.app/error}))
  (catch :my.app/error e :caught)))
EOF
)
assert_eq 'catch_keyword_namespaced_match' "$got" ':caught'

echo
echo "Phase 14 row 14.5 catch-by-keyword e2e: all green."
