#!/usr/bin/env bash
# test/clj/run_tier_a.sh
#
# §9.13 row 11.4 — Tier A 100% PASS gate. Runs the ported Clojure
# test corpus under cljw and asserts the final `[passes fails]`
# tuple has fails == 0.
#
# Tier A skip taxonomy (per ADR-0046) lives at
# `test/clj/skip_taxonomy.yaml`; today no skip rows exist because
# the cycle-1 ported set is hand-curated to live within cw v1's
# current surface (D-080 `=` number-only, D-075 metadata, D-099
# defmacro all worked around explicitly inside cw_ported.clj).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
# Honor the gate's shared-binary contract: skip the build when run_all.sh
# already built the optimised cljw (CLJW_SKIP_BUILD), else build ReleaseSafe
# (NOT a bare `zig build` = Debug, which would clobber the shared binary to
# Debug right before the parallel e2e pool — the ~100x silent perf cliff that
# made the whole gate take hours; D-385).
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

OUT=$("$BIN" test/clj/cw_ported.clj 2>&1) || {
    echo "FAIL test_clj exit non-zero" >&2
    echo "$OUT" >&2
    exit 1
}

LAST=$(echo "$OUT" | awk 'END { print }')
case "$LAST" in
    "[13 0]") echo "PASS test_clj Tier A 13/13 ($LAST)" ;;
    *)
        echo "FAIL test_clj Tier A — expected [13 0], got '$LAST'" >&2
        echo "$OUT" >&2
        exit 1
        ;;
esac
