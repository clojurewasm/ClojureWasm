#!/usr/bin/env bash
# Unified test runner. Single entry point so "what must succeed for the
# repository to be green" is unambiguous. Suites grow as phases land;
# do not add ad-hoc test scripts elsewhere — wire them in here.
#
# Per ADR-0024: run_step dispatcher with --list / --skip / --only / summary.
#
# Run on **both** the Mac host and Ubuntu x86_64 before every commit
# (CLAUDE.md "Working agreement"):
#
#   bash test/run_all.sh                                              # Mac
#   orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'         # Linux x86_64
#
# Setup for the Linux side: .dev/orbstack_setup.md.
#
# Flags (per ADR-0024):
#   --list                  List step names without running.
#   --skip name[,name,...]  Skip the named steps.
#   --only name[,name,...]  Run only the named steps.
#
# Exit code 0 iff every non-optional step passed. `optional` steps
# (e.g. bench/quick.sh once it lands) are reported but do not fail
# the run.

set -euo pipefail

cd "$(dirname "$0")/.."

# --- Flag parsing ---

LIST_ONLY=0
SKIP_STEPS=""
ONLY_STEPS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            LIST_ONLY=1
            shift
            ;;
        --skip)
            SKIP_STEPS="$2"
            shift 2
            ;;
        --only)
            ONLY_STEPS="$2"
            shift 2
            ;;
        *)
            echo "Unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

# --- run_step framework (per ADR-0024) ---

declare -a STEPS_PASSED=()
declare -a STEPS_FAILED=()
declare -a STEPS_FAILED_OPTIONAL=()
declare -a STEPS_SKIPPED=()
declare -a ALL_STEP_NAMES=()

step_in_csv() {
    local name="$1"
    local csv="$2"
    [[ -z "$csv" ]] && return 1
    [[ ",${csv}," == *",${name},"* ]]
}

run_step() {
    local name="$1"
    local cmd="$2"
    local optional="${3:-}"

    ALL_STEP_NAMES+=("$name")

    if (( LIST_ONLY )); then
        echo "$name${optional:+ (optional)}"
        return 0
    fi

    if [[ -n "$ONLY_STEPS" ]] && ! step_in_csv "$name" "$ONLY_STEPS"; then
        STEPS_SKIPPED+=("$name")
        return 0
    fi

    if step_in_csv "$name" "$SKIP_STEPS"; then
        echo "[skip] $name"
        STEPS_SKIPPED+=("$name")
        return 0
    fi

    echo "==> $name"
    local start
    start=$(date +%s)
    if eval "$cmd"; then
        local elapsed=$(( $(date +%s) - start ))
        echo "    [pass] (${elapsed}s)"
        STEPS_PASSED+=("$name")
    else
        local exit_code=$?
        local elapsed=$(( $(date +%s) - start ))
        echo "    [fail] (exit $exit_code, ${elapsed}s)"
        if [[ "$optional" == "optional" ]]; then
            STEPS_FAILED_OPTIONAL+=("$name")
        else
            STEPS_FAILED+=("$name")
        fi
    fi
}

print_summary() {
    echo ""
    echo "=== Summary ==="
    echo "  passed:           ${#STEPS_PASSED[@]}"
    echo "  failed:           ${#STEPS_FAILED[@]}"
    echo "  failed (optional): ${#STEPS_FAILED_OPTIONAL[@]}"
    echo "  skipped:          ${#STEPS_SKIPPED[@]}"

    if [[ ${#STEPS_FAILED_OPTIONAL[@]} -gt 0 ]]; then
        echo ""
        echo "  Failed optional (informational):"
        printf "    - %s\n" "${STEPS_FAILED_OPTIONAL[@]}"
    fi

    if [[ ${#STEPS_FAILED[@]} -gt 0 ]]; then
        echo ""
        echo "  Failed (blocking):"
        printf "    - %s\n" "${STEPS_FAILED[@]}"
        return 1
    fi
    return 0
}

# --- Steps ---

run_step "zig_build_test"      "zig build test"
run_step "zig_build_test_vm"   "zig build test -Dbackend=vm"
run_step "zone_check"           "bash scripts/zone_check.sh --gate"
run_step "surface_marker"       "bash scripts/check_surface_marker.sh --gate"
run_step "feature_keyword"      "bash scripts/check_feature_keyword.sh --gate"
# Hard-fail: any src/**/*.zig with test{} blocks that is not
# reachable from src/main.zig via @import (= Zig 0.16 lazy-decl-
# analysis silently skips its tests). See zig_tips.md "Test
# discovery via @import" + scripts/check_test_reach.sh.
run_step "test_reach"           "bash scripts/check_test_reach.sh --gate"

# zlinter no_deprecated gate (ADR-0003) — Mac-host only. zlinter is
# fetched via `zig fetch` against GitHub; OrbStack runs are network-
# free per .dev/orbstack_setup.md.
if [[ "$(uname -s)" == "Darwin" ]]; then
    run_step "zlinter"          "zig build lint -- --max-warnings 0"
fi

run_step "e2e_phase2_exit"     "bash test/e2e/phase2_exit.sh"
run_step "e2e_phase3_cli"      "bash test/e2e/phase3_cli.sh"
run_step "e2e_phase3_exit"     "bash test/e2e/phase3_exit.sh"
run_step "e2e_phase4_cli"        "bash test/e2e/phase4_cli.sh"
run_step "e2e_phase4_exit"       "bash test/e2e/phase4_exit.sh"
run_step "e2e_phase4_exit_codes" "bash test/e2e/phase4_exit_codes.sh"
run_step "e2e_phase5_exit"       "bash test/e2e/phase5_exit.sh"
run_step "e2e_phase6_regex_cycle1" "bash test/e2e/phase6_regex_cycle1.sh"
run_step "e2e_phase6_clojure_string_cycle1" "bash test/e2e/phase6_clojure_string_cycle1.sh"
run_step "e2e_phase6_clojure_string_cycle2" "bash test/e2e/phase6_clojure_string_cycle2.sh"
run_step "e2e_phase6_clojure_string_cycle3" "bash test/e2e/phase6_clojure_string_cycle3.sh"
run_step "e2e_phase6_clojure_string_cycle4" "bash test/e2e/phase6_clojure_string_cycle4.sh"
run_step "e2e_phase6_clojure_set_cycle1" "bash test/e2e/phase6_clojure_set_cycle1.sh"
run_step "e2e_phase6_clojure_set_cycle2" "bash test/e2e/phase6_clojure_set_cycle2.sh"
run_step "e2e_phase6_clojure_walk_cycle1" "bash test/e2e/phase6_clojure_walk_cycle1.sh"
run_step "e2e_phase6_16_a_0_metadata"      "bash test/e2e/phase6_16_a_0_metadata.sh"
run_step "e2e_composition_unlock_a1"       "bash test/e2e/composition_unlock_a1.sh"
run_step "e2e_composition_unlock_a2"       "bash test/e2e/composition_unlock_a2.sh"
run_step "e2e_composition_unlock_a3_1"     "bash test/e2e/composition_unlock_a3_1.sh"
run_step "e2e_transducer_unlock_a3"        "bash test/e2e/transducer_unlock_a3.sh"
run_step "e2e_phase6_clojure_set_group_ab" "bash test/e2e/phase6_clojure_set_group_ab.sh"

# Informational scans (ADR-0024). Phase 5+ they become blocking.
run_step "scan_catalog_only"   "bash scripts/scan_catalog_only.sh" optional
run_step "scan_panic_audit"    "bash scripts/scan_panic_audit.sh"  optional

# Bench quick — Phase 4 observability (per ROADMAP §10.2). Records
# numbers, never fails the build until §10.1 lock at Phase 8.
run_step "bench_quick"         "PHASE_NAME=phase4 bash bench/quick.sh" optional

# Future suites (uncomment as their phase lands):
#   run_step "diff_runner"  "zig build test -Dtest-filter='differential cases'"
#   run_step "test_clj"     "bash scripts/run_clj_tests.sh"  # Phase 11
#   run_step "tier_check"   "bash scripts/tier_check.sh"     # Phase 14

# --- Summary ---

if (( LIST_ONLY )); then
    exit 0
fi

print_summary
