#!/usr/bin/env bash
# Unified test runner.
#
# Single entry point so "what must succeed for the repository to be green"
# is unambiguous. Suites grow as phases land; do not add ad-hoc test
# scripts elsewhere — wire them in here.
#
# Current suites:
#   1. zig build test           — Zig unit tests in each src/**/*.zig file.
#
# Future suites (added when their phase lands):
#   - test/e2e/*.sh             — CLI round-trip checks               (Phase 2)
#   - test/clj/**/*.clj         — clojure.test suites                 (Phase 11)
#   - test/upstream/**/*.clj    — upstream-ported Tier-A verification (Phase 11)
#   - bash scripts/zone_check.sh --gate  — zone violation gate        (Phase 2)
#   - bash scripts/tier_check.sh         — compat_tiers.yaml verify   (Phase 14)
#
# Exit code 0 ↔ every suite passed. Any failure exits immediately.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> 1. zig build test"
zig build test
echo "    OK"

# When the second suite lands, uncomment and wire here:
# if [ -x "test/e2e/cli_smoke.sh" ]; then
#     echo "==> 2. CLI smoke (test/e2e/cli_smoke.sh)"
#     bash test/e2e/cli_smoke.sh
#     echo "    OK"
# fi

echo
echo "All test suites passed."
