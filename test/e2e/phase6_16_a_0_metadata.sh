#!/usr/bin/env bash
# test/e2e/phase6_16_a_0_metadata.sh
#
# Phase 6.16.a-0 EXIT smoke — env.intern API metadata expansion +
# analyzer ^:private cross-ns check + analyzer ^:unsupported call
# check. Backs ADR-0033 D8 + D-065.
#
# Coverage notes:
# - Unit-level coverage (intern with MetadataMap, applyMetadata, flag
#   storage) lives in src/runtime/env.zig + src/eval/analyzer/analyzer.zig.
# - This Layer-2 e2e exercises the end-to-end render-error path so we
#   catch any catalog template / error rendering regression.
# - Phase 6.16.a-0 does NOT install any user-facing private leaf yet;
#   metadata gets exercised at Layer 1 unit only. The e2e here focuses
#   on the existing surface (no new vars touched at cycle 6.16.a-0).
#   Once Phase 6.16.a-1+ installs Pattern B2 leaves with `-name` +
#   `^:private :zig-leaf` metadata, the cross-ns block surfaces
#   in `composition_unlock_a1.sh` and downstream e2e tests.

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

# --- (1) sanity: existing intern with null metadata still works ---
# All Phase 6.x primitives intern themselves with `null` metadata
# after the signature expansion. If this fails, the metadata
# expansion broke the existing path.
got="$("$BIN" -e '(+ 1 2)')"
assert_eq 'baseline_add' "$got" '3'

got="$("$BIN" -e '(clojure.string/upper-case "hi")')"
assert_eq 'baseline_string_upper' "$got" '"HI"'

got="$("$BIN" -e '(clojure.set/union (hash-set 1) (hash-set 2))')"
assert_eq 'baseline_set_union' "$got" '#{1 2}'

got="$("$BIN" -e '(clojure.walk/walk inc identity [1 2 3])')"
assert_eq 'baseline_walk' "$got" '[2 3 4]'

# --- (2) symbol unresolved still names the catalog code clearly ---
# Confirms the analyzer error-rendering path that
# `private_access_error` / `feature_not_supported_unsupported_var`
# both reuse is unchanged.
got="$("$BIN" -e '(no-such-var)' 2>&1 || true)"
if ! grep -q 'Name error' <<<"$got"; then
    fail "unresolved_symbol_kind: did not render [name_error] tag (got '$got')"
fi
if ! grep -q "Unable to resolve symbol" <<<"$got"; then
    fail "unresolved_symbol_message: did not render canonical message (got '$got')"
fi
echo "PASS unresolved_symbol_renders_name_error"

echo ""
echo "=== phase6_16_a_0_metadata: all assertions passed ==="
