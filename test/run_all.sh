#!/usr/bin/env bash
# Unified test runner. Single entry point so "what must succeed for the
# repository to be green" is unambiguous. Suites grow as phases land;
# do not add ad-hoc test scripts elsewhere — wire them in here.
#
# Active suites:
#   1. zig build test           Zig unit tests in each src/**/*.zig
#   2. scripts/zone_check.sh    zone-dependency gate (--gate mode)
#
# Future suites (uncomment as their phase lands):
#   - test/e2e/*.sh             CLI round-trip checks               (Phase 2)
#   - test/clj/**/*.clj         clojure.test suites                 (Phase 11)
#   - test/upstream/**/*.clj    upstream-ported Tier-A verification (Phase 11)
#   - bash scripts/tier_check.sh                                    (Phase 14)
#
# Exit code 0 iff every suite passed. Any failure exits immediately.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> 1. zig build test"
zig build test
echo "    OK"

echo "==> 2. zone_check --gate"
bash scripts/zone_check.sh --gate
echo "    OK"

# if [ -x test/e2e/cli_smoke.sh ]; then
#     echo "==> 3. CLI smoke (test/e2e/cli_smoke.sh)"
#     bash test/e2e/cli_smoke.sh
#     echo "    OK"
# fi

echo
echo "All test suites passed."
