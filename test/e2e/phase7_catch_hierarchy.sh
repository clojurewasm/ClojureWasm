#!/usr/bin/env bash
# test/e2e/phase7_catch_hierarchy.sh
#
# Phase 7 §9.9 row 7.11 — D-077 catch-class hierarchy + analyzer-time
# unknown-class rejection. Discharges the silent-default-shift smell
# where `(catch ClassName e ...)` with any class other than
# `ExceptionInfo` used to silently become dead code.
#
# Cycle 2 wired both backends through `host_class.matches` so the
# parent-chain walk works (Throwable / Exception / RuntimeException /
# ExceptionInfo). Cycle 3 added the analyzer-time `catch_class_unknown`
# raise so the failure mode is loud, not silent.

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

# --- Case 1: bare ExceptionInfo (unchanged from cycle 1) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(try (throw (ex-info "boom" {})) (catch ExceptionInfo e (ex-message e)))
EOF
)
assert_eq 'catch_exception_info_direct' "$got" '"boom"'

# --- Case 2: catch Throwable matches everything ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(try (throw (ex-info "boom" {})) (catch Throwable e (ex-message e)))
EOF
)
assert_eq 'catch_throwable_matches_all' "$got" '"boom"'

# --- Case 3: catch Exception via RuntimeException via ExceptionInfo (parent walk) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(try (throw (ex-info "boom" {})) (catch Exception e (ex-message e)))
EOF
)
assert_eq 'catch_exception_parent_walk' "$got" '"boom"'

# --- Case 4: sibling IOException does NOT match ExceptionInfo ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(try (throw (ex-info "boom" {}))
  (catch IOException e :wrong)
  (catch ExceptionInfo e :ok))
EOF
)
assert_eq 'catch_sibling_skip' "$got" ':ok'

# --- Case 5: FQCN java.lang.RuntimeException normalises to simple ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(try (throw (ex-info "boom" {})) (catch java.lang.RuntimeException e :caught))
EOF
)
assert_eq 'catch_fqcn_normalise' "$got" ':caught'

# --- Case 6: unknown class raises analyzer-time catch_class_unknown ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(try (throw (ex-info "x" {})) (catch FooBarException e :wrong))
EOF
)
case "$diag" in
    *"catch class 'FooBarException' is not a known exception type"*)
        echo "PASS catch_unknown_class_raises -> diagnostic" ;;
    *)
        fail "catch_unknown_class_raises: missing diagnostic ($diag)" ;;
esac

echo
echo "Phase 7 row 7.11 catch hierarchy e2e: all green."
