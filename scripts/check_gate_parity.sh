#!/usr/bin/env bash
# check_gate_parity.sh — the local full gate and the CI full gate must run the
# SAME configuration.
#
#   bash scripts/check_gate_parity.sh
#
# `scripts/ci_gate.sh` says, in its own header, "FULL gate == the LOCAL full
# gate … (test/run_all.sh --serial-e2e)". That sentence was false for months:
# `ci_gate.sh` passed `--serial-e2e`, `run_gate.sh` passed nothing, and
# `run_all.sh` defaults to `PARALLEL_E2E=1`. So "the local full gate is green"
# and "CI is green" were statements about two different test runs.
#
# It is not a theoretical gap. The parallel path captures each job's output to a
# file; the serial path pipes it. An e2e whose producer took SIGPIPE from a
# `head -N` therefore died silently under serial and passed under parallel —
# green on every local full gate, red on every push (2026-08-04).
#
# Two launchers can stay, but their agreement has to be executed rather than
# asserted in a comment. That is the whole content of this check.
#
# 2026-08-12: extended from "both pass --serial-e2e" to "there is exactly ONE
# configuration". CI used to run tiers — PR got `--smoke`, the nightly got the
# full gate PLUS a tree_walk sweep of corpus + every e2e — so three different
# runs could each be called green. The nightly's last run failed on a 5-second
# wall-clock bound in that extra config and nowhere else; the same bind measures
# 0.08-0.14 s locally on the same build, so the tier's only finding was about
# the runner. Tiers are gone, and the checks below make their return a gate
# failure rather than a review-time thing to notice.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
note() { echo "check_gate_parity: $1" >&2; fail=1; }

# The full-gate configuration is ONE registry row, and the CLI resolves it.
# `--dry-run` runs nothing, so this is the configuration itself, not a grep for
# a sentence about it.
FULL_CMD="bash test/run_all.sh --serial-e2e"
resolved="$(bash test/cljw-test --only full --dry-run 2>/dev/null || true)"
[[ "$resolved" == "full: $FULL_CMD" ]] \
    || note "test/cljw-test --only full resolves to '${resolved:-<nothing>}', expected 'full: $FULL_CMD' — the registry row that defines the gate changed."

# CI reaches the suite only through the CLI, so the row above is the single
# definition rather than a string repeated per launcher.
code_of() { grep -vE '^\s*#' "$1"; }
code_of scripts/ci_gate.sh | grep -qE '^\s*bash test/run_all.sh' \
    && note "scripts/ci_gate.sh calls test/run_all.sh directly — it must go through test/cljw-test --only full, or CI stops resolving the registry row."
n_full="$(code_of scripts/ci_gate.sh | grep -cE '^\s*bash test/cljw-test --only full$' || true)"
[[ "$n_full" == "1" ]] \
    || note "scripts/ci_gate.sh runs 'test/cljw-test --only full' $n_full time(s) — expected exactly 1; a tier is back, so CI would run something local does not."

grep -q -- 'MODE=(--serial-e2e)' scripts/run_gate.sh \
    || note "scripts/run_gate.sh no longer defaults to --serial-e2e, so the local full gate would validate a different configuration from CI."

# `run_all.sh` still has to HAVE the flag for either to mean anything.
grep -q -- '--serial-e2e)' test/run_all.sh \
    || note "test/run_all.sh no longer accepts --serial-e2e; both launchers are passing a flag it ignores."

# --- ONE configuration: no CI-only tier may come back. ---
#
# These greps read CODE, not prose: the headers below deliberately NAME the
# retired switches to explain why they are gone, and a check that counted a
# comment would fire on its own documentation. Comment lines are stripped by
# code_of, defined above.
code_of scripts/ci_gate.sh | grep -qE 'CLJW_CI_(FULL|PARITY)' \
    && note "scripts/ci_gate.sh branches on CLJW_CI_FULL/PARITY again — that is the tiering this check exists to keep out."

# The workflow must not re-introduce a tier by env either. (A schedule is fine
# in principle — but only if it runs the SAME gate, which means no CLJW_CI_*
# switch exists to make it differ.)
if [[ -f .github/workflows/ci.yml ]]; then
    code_of .github/workflows/ci.yml | grep -qE 'CLJW_CI_(FULL|PARITY)' \
        && note ".github/workflows/ci.yml sets CLJW_CI_FULL/PARITY — CI would verify a different configuration from the local gate."
fi

# The non-default-backend sweep is an on-demand tool. If it is wired into a
# launcher, it is a CI-vs-local difference again.
code_of scripts/ci_gate.sh | grep -q 'check_vm_parity.sh' \
    && note "scripts/ci_gate.sh runs check_vm_parity.sh — that sweep is on-demand, not part of the gate."

if [[ "$fail" -ne 0 ]]; then
    echo "  A local 'full gate green' must mean the same run CI will do. Fix the launcher, or" >&2
    echo "  change BOTH and update ci_gate.sh's header claim in the same commit." >&2
    exit 1
fi
echo "    gate_parity: one configuration — test/units.list 'full' is $FULL_CMD, ci_gate.sh reaches it through test/cljw-test, run_gate.sh runs it directly, no CI-only tier"
