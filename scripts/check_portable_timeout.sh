#!/usr/bin/env bash
# check_portable_timeout.sh — no bare `timeout` in anything the gate runs.
#
# The CI macOS runner ships neither GNU `timeout` nor coreutils `gtimeout`:
# a bare `timeout 30 cmd` exits 127 there, so the step fails at 0s — locally
# green, red on every push. This class has now bitten twice:
#   2026-08-04  scripts/check_doc_coverage.sh   (fixed with run_bounded)
#   2026-08-05  test/e2e/budget_thread_ownership.sh
# Both times the fix already existed in-repo (`run_bounded`: timeout, else
# gtimeout, else unbounded) and was not used because nothing enforced it.
# This check is the enforcement: local-vs-CI parity must be mechanical, not
# a thing each author remembers (same posture as check_epipe_head.sh and
# gate_parity for their classes).
#
# Scope = what the gate executes: every test/e2e/*.sh, plus every
# scripts/*.sh referenced by test/run_all.sh. Dev-machine tools that REQUIRE
# a JVM clj (clj_diff_sweep, lib_conformance, extract_core_meta,
# verify_projects) never run on CI and are exempt — listed explicitly so a
# new gate reference to one of them trips this check and forces the
# decision.
set -euo pipefail
cd "$(dirname "$0")/.."

EXEMPT='lib_conformance.sh|extract_core_meta.sh|verify_projects.sh|run_remote_ubuntu.sh|run_gate.sh'

# Gate-reachable scripts: e2e + scripts named in run_all.sh.
files=(test/e2e/*.sh)
while IFS= read -r f; do
    [[ -f "$f" ]] && files+=("$f")
done < <(grep -oE 'scripts/[a-z_0-9]+\.sh' test/run_all.sh | sort -u)

fail=0
for f in "${files[@]}"; do
    base=$(basename "$f")
    [[ "$base" =~ ^($EXEMPT)$ ]] && continue
    # A bare invocation is `timeout <digits>` at a command position, outside
    # the `command -v timeout` feature-probe line of a run_bounded helper.
    hits=$(grep -nE '(^|[ \t(;&|])g?timeout +[0-9]' "$f" | grep -v 'command -v' || true)
    if [[ -n "$hits" ]]; then
        echo "check_portable_timeout: bare timeout in $f (CI macOS has none — use a run_bounded helper):" >&2
        sed 's/^/    /' <<< "$hits" >&2
        fail=1
    fi
done

if [[ "$fail" -eq 0 ]]; then
    echo "check_portable_timeout: ok — no bare timeout in gate-reachable scripts"
fi
exit "$fail"
