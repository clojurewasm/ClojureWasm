#!/usr/bin/env bash
# Unified test runner. Single entry point so "what must succeed for the
# repository to be green" is unambiguous. Suites grow as phases land;
# do not add ad-hoc test scripts elsewhere — wire them in here.
#
# Per ADR-0024: run_step dispatcher with --list / --skip / --only / summary.
#
# Per-commit gate: Mac host only as of ADR-0049 (2026-05-28).
# Linux x86_64 gate moved to manual / Phase-boundary via the
# `ubuntunote` SSH host:
#
#   bash test/run_all.sh                  # Mac per-commit
#   bash scripts/run_remote_ubuntu.sh     # Linux at Phase boundary
#
# Setup: .dev/ubuntunote_setup.md (Linux SSH host) +
# .dev/orbstack_setup.md (retained dev-convenience host).
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
run_step "e2e_phase6_set_map_literal"      "bash test/e2e/phase6_set_map_literal.sh"
run_step "e2e_phase6_clojure_set_group_c"  "bash test/e2e/phase6_clojure_set_group_c.sh"
run_step "e2e_phase6_16_b_4_private_leaf"  "bash test/e2e/phase6_16_b_4_private_leaf.sh"
run_step "e2e_phase6_16_b_4_require_basic" "bash test/e2e/phase6_16_b_4_require_basic.sh"
run_step "e2e_phase6_16_b_4_require_libspec" "bash test/e2e/phase6_16_b_4_require_libspec.sh"
run_step "e2e_phase6_16_b_4_ns_macro"        "bash test/e2e/phase6_16_b_4_ns_macro.sh"
run_step "e2e_phase6_16_c_walk_pattern_a"    "bash test/e2e/phase6_16_c_walk_pattern_a.sh"
run_step "e2e_phase6_16_c_keyword_name"      "bash test/e2e/phase6_16_c_keyword_name.sh"
run_step "e2e_phase6_16_d_clojure_string_shim" "bash test/e2e/phase6_16_d_clojure_string_shim.sh"
run_step "e2e_phase6_exit_smoke"             "bash test/e2e/phase6_exit_smoke.sh"
run_step "e2e_phase7_symbol_value"           "bash test/e2e/phase7_symbol_value.sh"
run_step "e2e_phase7_multimethod"            "bash test/e2e/phase7_multimethod.sh"
run_step "e2e_phase7_protocol"               "bash test/e2e/phase7_protocol.sh"
run_step "e2e_phase7_defrecord"              "bash test/e2e/phase7_defrecord.sh"
run_step "e2e_phase7_reify"                  "bash test/e2e/phase7_reify.sh"
run_step "e2e_phase7_method_dispatch"        "bash test/e2e/phase7_method_dispatch.sh"
run_step "e2e_phase7_polymorphic_extend"     "bash test/e2e/phase7_polymorphic_extend.sh"
run_step "e2e_phase7_multi_arity"            "bash test/e2e/phase7_multi_arity.sh"
run_step "e2e_phase7_apply_variadic"         "bash test/e2e/phase7_apply_variadic.sh"
run_step "e2e_phase7_catch_hierarchy"        "bash test/e2e/phase7_catch_hierarchy.sh"
run_step "e2e_phase7_instance_q"             "bash test/e2e/phase7_instance_q.sh"
run_step "e2e_phase7_replace_pattern_a"      "bash test/e2e/phase7_replace_pattern_a.sh"
run_step "e2e_phase7_zip_cycle1"             "bash test/e2e/phase7_zip_cycle1.sh"
run_step "e2e_phase7_zip_cycle2"             "bash test/e2e/phase7_zip_cycle2.sh"
run_step "e2e_phase7_zip_cycle3"             "bash test/e2e/phase7_zip_cycle3.sh"
run_step "e2e_phase7_zip_cycle4"             "bash test/e2e/phase7_zip_cycle4.sh"
run_step "e2e_phase7_exit_smoke"             "bash test/e2e/phase7_exit_smoke.sh"
run_step "e2e_phase8_compare_cli"            "bash test/e2e/phase8_compare_cli.sh"
run_step "e2e_phase8_d089_seq_extend"        "bash test/e2e/phase8_d089_seq_extend.sh"
run_step "e2e_phase8_d089_lookup_extend"     "bash test/e2e/phase8_d089_lookup_extend.sh"
run_step "e2e_phase8_d089_assoc_extend"      "bash test/e2e/phase8_d089_assoc_extend.sh"
run_step "e2e_phase8_d089_set_extend"        "bash test/e2e/phase8_d089_set_extend.sh"
run_step "e2e_phase8_exit_smoke"             "bash test/e2e/phase8_exit_smoke.sh"
run_step "e2e_phase9_edn_read_string"        "bash test/e2e/phase9_edn_read_string.sh"
run_step "e2e_phase9_json"                   "bash test/e2e/phase9_json.sh"
run_step "e2e_phase9_csv"                    "bash test/e2e/phase9_csv.sh"
run_step "e2e_phase9_cli"                    "bash test/e2e/phase9_cli.sh"
run_step "e2e_phase9_exit_smoke"             "bash test/e2e/phase9_exit_smoke.sh"
run_step "e2e_phase10_pprint"                "bash test/e2e/phase10_pprint.sh"
run_step "e2e_phase10_exit_smoke"            "bash test/e2e/phase10_exit_smoke.sh"
run_step "e2e_phase11_clojure_test"          "bash test/e2e/phase11_clojure_test.sh"
run_step "test_clj_tier_a"                   "bash test/clj/run_tier_a.sh"
run_step "e2e_phase11_exit_smoke"            "bash test/e2e/phase11_exit_smoke.sh"
run_step "e2e_phase13_exit_smoke"            "bash test/e2e/phase13_exit_smoke.sh"
run_step "e2e_phase14_catch_keyword"         "bash test/e2e/phase14_catch_keyword.sh"
run_step "e2e_phase14_binding"               "bash test/e2e/phase14_binding.sh"
run_step "e2e_phase14_with_context"          "bash test/e2e/phase14_with_context.sh"
run_step "e2e_phase14_user_throw"            "bash test/e2e/phase14_user_throw.sh"
run_step "e2e_phase14_fn_macro"              "bash test/e2e/phase14_fn_macro.sh"
run_step "e2e_phase14_anon_fn_reader"        "bash test/e2e/phase14_anon_fn_reader.sh"
run_step "e2e_phase14_defmacro_user"         "bash test/e2e/phase14_defmacro_user.sh"
run_step "e2e_phase14_ns_directive"          "bash test/e2e/phase14_ns_directive.sh"
run_step "e2e_phase14_future_promise_delay"  "bash test/e2e/phase14_future_promise_delay.sh"
run_step "e2e_phase14_repl"                  "bash test/e2e/phase14_repl.sh"
run_step "e2e_phase14_nrepl"                 "bash test/e2e/phase14_nrepl.sh"
run_step "e2e_phase14_error_format"          "bash test/e2e/phase14_error_format.sh"
run_step "e2e_phase14_cold_start_threshold"  "bash test/e2e/phase14_cold_start_threshold.sh"
run_step "e2e_phase14_render_error"          "bash test/e2e/phase14_render_error.sh"
run_step "e2e_phase14_java_static_dispatch"  "bash test/e2e/phase14_java_static_dispatch.sh"
run_step "e2e_phase14_instance_member"       "bash test/e2e/phase14_instance_member.sh"
run_step "e2e_phase14_math"                  "bash test/e2e/phase14_math.sh"
run_step "e2e_phase14_destructure"           "bash test/e2e/phase14_destructure.sh"
run_step "e2e_phase14_map_string_keys"       "bash test/e2e/phase14_map_string_keys.sh"
run_step "e2e_phase14_float_print"           "bash test/e2e/phase14_float_print.sh"
run_step "e2e_phase14_cljw_build"            "bash test/e2e/phase14_cljw_build.sh"
run_step "e2e_phase14_core_cluster"          "bash test/e2e/phase14_core_cluster.sh"
run_step "e2e_phase14_print_family"          "bash test/e2e/phase14_print_family.sh"
run_step "e2e_phase14_coll_helpers"          "bash test/e2e/phase14_coll_helpers.sh"
run_step "e2e_phase14_map_helpers"           "bash test/e2e/phase14_map_helpers.sh"
run_step "e2e_phase14_equality"              "bash test/e2e/phase14_equality.sh"
run_step "e2e_phase14_dedup_group"           "bash test/e2e/phase14_dedup_group.sh"
run_step "e2e_phase14_seq_helpers2"          "bash test/e2e/phase14_seq_helpers2.sh"
run_step "e2e_phase14_reduce_helpers"        "bash test/e2e/phase14_reduce_helpers.sh"
run_step "e2e_phase14_accessors"             "bash test/e2e/phase14_accessors.sh"
run_step "e2e_phase14_compare"               "bash test/e2e/phase14_compare.sh"
run_step "e2e_phase14_sort"                  "bash test/e2e/phase14_sort.sh"
run_step "e2e_phase14_range_indexed"         "bash test/e2e/phase14_range_indexed.sh"
run_step "e2e_phase14_lazy_seq"              "bash test/e2e/phase14_lazy_seq.sh"
run_step "e2e_phase14_lazy_map"              "bash test/e2e/phase14_lazy_map.sh"
run_step "e2e_phase14_lazy_seq_cycle3"       "bash test/e2e/phase14_lazy_seq_cycle3.sh"
run_step "e2e_phase14_lazy_seq_cycle4"       "bash test/e2e/phase14_lazy_seq_cycle4.sh"
run_step "e2e_phase14_exit_smoke"            "bash test/e2e/phase14_exit_smoke.sh"

# Informational scans (ADR-0024). Phase 5+ they become blocking.
run_step "scan_catalog_only"   "bash scripts/scan_catalog_only.sh" optional
run_step "scan_panic_audit"    "bash scripts/scan_panic_audit.sh"  optional

# Bench quick — Phase 4 observability (per ROADMAP §10.2). Records
# numbers, never fails the build until §10.1 lock at Phase 8.
run_step "bench_quick"         "PHASE_NAME=phase4 bash bench/quick.sh" optional

# Row 8.3 (ADR-0027): 1.2x regression gate. Informational at this
# wiring point — flips to `--gate` once row 8.7 exit-smoke confirms
# stable thresholds across both hosts. Reads the latest
# `bench/quick_baseline.txt` block for the current (machine, backend)
# tuple + compares against the matching `bench/history.yaml` lock.
run_step "bench_regression"    "bash scripts/check_bench_regression.sh --check" optional

# Future suites (uncomment as their phase lands):
#   run_step "diff_runner"  "zig build test -Dtest-filter='differential cases'"
#   run_step "test_clj"     "bash scripts/run_clj_tests.sh"  # Phase 11
#   run_step "tier_check"   "bash scripts/tier_check.sh"     # Phase 14

# --- Summary ---

if (( LIST_ONLY )); then
    exit 0
fi

print_summary
