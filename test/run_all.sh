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
# (e.g. the informational scans) are reported but do not fail the run.

set -euo pipefail

cd "$(dirname "$0")/.."

# --- Flag parsing ---

LIST_ONLY=0
SKIP_STEPS=""
ONLY_STEPS=""
# Functional e2e steps run concurrently (they are independent cljw spawns);
# they make up ~60% of the gate wall-time and are embarrassingly parallel.
# Steps that must stay serial are listed in SERIAL_STEPS below. --serial-e2e
# forces the old sequential path (used to validate parity).
PARALLEL_E2E=1
RESUME=0
E2E_JOBS="${E2E_JOBS:-8}"
# ADR-0107 two-tier gate: --smoke runs the fast, contention-tolerant correctness
# core (zig build test ×2 = the FULL dual-backend diff oracle + all unit, + lint
# + build_cljw + corpus_regression) plus any changed/new e2e step(s) named after
# the flag, then stamps .dev/.smoke_pass. This is the per-commit check; the slow
# 248-step e2e SHELL suite + perf run only in the full (no-flag) gate, batched +
# run-alone. The single .dev/.gate_cadence ceiling (full gate resets it) bounds
# how many smoke-only commits ride before a full gate is forced.
SMOKE_MODE=0
SMOKE_E2E=""
SMOKE_CORE="zig_build_test_vm,zig_build_test_tree_walk,zlinter,build_cljw,corpus_regression"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --smoke)
            SMOKE_MODE=1
            # Optional comma-list of e2e step names to include (the unit's
            # changed/new e2e), e.g. `--smoke e2e_phase14_random`.
            if [[ $# -ge 2 && "$2" != --* ]]; then
                SMOKE_E2E="$2"
                shift 2
            else
                shift
            fi
            ;;
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
        --serial-e2e)
            PARALLEL_E2E=0
            shift
            ;;
        --resume)
            # D-385: skip steps that already passed for the CURRENT source
            # content (content-fingerprint keyed). A re-run after a timeout
            # continues instead of redoing from scratch. A code change flips the
            # fingerprint → the ledger no longer matches → full re-run (safe).
            RESUME=1
            shift
            ;;
        --jobs)
            E2E_JOBS="$2"
            shift 2
            ;;
        *)
            echo "Unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

# ADR-0107: in --smoke mode, restrict to the correctness core + the named e2e
# step(s). Everything else (the 248-step e2e shell suite + perf) is skipped; it
# runs only in the full gate. Implemented by funneling through the existing
# ONLY_STEPS machinery so run_step's selection logic is reused unchanged.
if (( SMOKE_MODE )); then
    ONLY_STEPS="${SMOKE_CORE}${SMOKE_E2E:+,$SMOKE_E2E}"
fi

# Steps that must NOT run in the parallel e2e pool. Two reasons:
#   1. phase8_exit_smoke: spawns many short cljw processes whose timing
#      inflates under 8-way CPU contention (it ballooned 3s → 142s once).
#   2. Shared-binary mutators: the 3 backend-forcing phase4_* e2e run
#      `zig build -Dbackend=…`, rewriting the shared zig-out/bin/cljw (and
#      contending the zig cache) mid-run; concurrent pool jobs that exec the
#      binary then hit a half-written file. They restore the default binary
#      at their end, so running them serially in the registration pass —
#      before the flush — leaves the pool a correct, stable binary.
# These run serially BEFORE the parallel flush, on a quiet machine.
SERIAL_STEPS="e2e_phase8_exit_smoke,e2e_phase4_cli,e2e_phase4_exit,e2e_phase4_exit_codes,e2e_phase16_http_server,e2e_phase16_http_client"
declare -a E2E_QUEUE=()

# Steps that MUST run on every pass, even under --resume. These are
# environment setup (not tests): they establish the shared optimised
# `zig-out/bin/cljw` that all e2e steps then reuse (CLJW_SKIP_BUILD).
# If `build_cljw` is resume-skipped, the ReleaseSafe binary is never
# (re)built and e2e silently runs against a stale Debug binary at
# ~1.7s/spawn vs ~5ms (~100x), turning the gate into hours with NO test
# failure (D-385 silent perf cliff). `assert_e2e_releasesafe` is the loud
# guard for the same invariant. Both are cheap (cache-hit build, one stat).
NO_RESUME_STEPS="build_cljw,assert_e2e_releasesafe"

# --- run_step framework (per ADR-0024) ---

declare -a STEPS_PASSED=()
declare -a STEPS_FAILED=()
declare -a STEPS_FAILED_OPTIONAL=()
declare -a STEPS_SKIPPED=()
declare -a ALL_STEP_NAMES=()
declare -a STEP_TIMES=()   # D-385: "<elapsed_s> <name>" per step, for the summary
GATE_START=$(date +%s)     # D-385: total wall-clock baseline

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

    # D-385 resume: this step already passed for the current source content.
    # NO_RESUME_STEPS (env-setup like build_cljw) are exempt — they must run
    # every pass to keep the shared ReleaseSafe e2e binary correct (see the
    # NO_RESUME_STEPS comment; resume-skipping build_cljw was the silent
    # ~100x perf cliff behind the multi-hour gate).
    if resume_done "$name" && ! step_in_csv "$name" "$NO_RESUME_STEPS"; then
        echo "[resume-skip] $name"
        STEPS_SKIPPED+=("$name")
        return 0
    fi

    # Defer functional e2e into the parallel pool (flushed at the end).
    # Optional steps and perf-sensitive steps stay on the serial path.
    if (( PARALLEL_E2E )) && [[ "$name" == e2e_* ]] && [[ -z "$optional" ]] \
        && ! step_in_csv "$name" "$SERIAL_STEPS"; then
        E2E_QUEUE+=("${name}|${cmd}")
        return 0
    fi

    echo "==> $name"
    local start
    start=$(date +%s)
    if eval "$cmd"; then
        local elapsed=$(( $(date +%s) - start ))
        echo "    [pass] (${elapsed}s)"
        STEPS_PASSED+=("$name")
        record_pass "$name"
        STEP_TIMES+=("$elapsed $name")  # D-385: per-step timing for the slowest-N summary
    else
        local exit_code=$?
        local elapsed=$(( $(date +%s) - start ))
        echo "    [fail] (exit $exit_code, ${elapsed}s)"
        STEP_TIMES+=("$elapsed $name")  # D-385
        if [[ "$optional" == "optional" ]]; then
            STEPS_FAILED_OPTIONAL+=("$name")
        else
            STEPS_FAILED+=("$name")
        fi
    fi
}

# Run the deferred functional e2e steps concurrently (sliding pool of
# E2E_JOBS workers via `wait -n`). Each job writes pass/fail + captured
# output to its own temp file; results are aggregated in queue order so
# the report reads the same as the serial path. Called once, after every
# serial step has run, so the perf-sensitive steps already measured on a
# quiet machine.
flush_e2e_queue() {
    (( ${#E2E_QUEUE[@]} == 0 )) && return 0
    echo "==> e2e (parallel, ${#E2E_QUEUE[@]} steps, -P${E2E_JOBS})"
    local tmpdir; tmpdir=$(mktemp -d)
    local idx=0
    declare -a qnames=()
    local entry name cmd jid
    for entry in "${E2E_QUEUE[@]}"; do
        name="${entry%%|*}"
        cmd="${entry#*|}"
        qnames+=("$name")
        # Throttle to E2E_JOBS in flight. `wait -n` returns a failed job's
        # status; guard with `|| true` so `set -e` does not abort the pool.
        while (( $(jobs -rp | wc -l) >= E2E_JOBS )); do wait -n || true; done
        jid=$idx
        (
            local s; s=$(date +%s)
            if eval "$cmd" >"$tmpdir/$jid.out" 2>&1; then
                printf 'pass %s' "$(( $(date +%s) - s ))" >"$tmpdir/$jid.res"
            else
                printf 'fail %s' "$?" >"$tmpdir/$jid.res"
            fi
        ) &
        idx=$((idx + 1))
    done
    wait || true
    local j res
    for (( j = 0; j < idx; j++ )); do
        name="${qnames[$j]}"
        res=$(cat "$tmpdir/$j.res" 2>/dev/null || echo "fail ?")
        if [[ "$res" == pass* ]]; then
            echo "    [pass] ${name} (${res#pass }s)"
            STEPS_PASSED+=("$name")
            record_pass "$name"
            STEP_TIMES+=("${res#pass } $name")  # D-385: per-step timing for the slowest-N summary
        else
            echo "    [fail] ${name} (exit ${res#fail })"
            sed 's/^/        /' "$tmpdir/$j.out" 2>/dev/null | tail -25
            STEPS_FAILED+=("$name")
        fi
    done
    rm -rf "$tmpdir"
}

print_summary() {
    echo ""
    echo "=== Summary ==="
    echo "  passed:           ${#STEPS_PASSED[@]}"
    echo "  failed:           ${#STEPS_FAILED[@]}"
    echo "  failed (optional): ${#STEPS_FAILED_OPTIONAL[@]}"
    echo "  skipped:          ${#STEPS_SKIPPED[@]}"

    # D-385: total wall-clock + the 10 slowest steps, so gate-efficiency work is
    # data-driven (which steps actually dominate the ~30-min run).
    echo "  total wall:       $(( $(date +%s) - GATE_START ))s"
    if [[ ${#STEP_TIMES[@]} -gt 0 ]]; then
        echo ""
        echo "  Slowest steps (s):"
        printf '%s\n' "${STEP_TIMES[@]}" | sort -rn | head -10 | sed 's/^/    /'
    fi

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

# --- D-385 resume ledger ---
# A step that passed for the CURRENT source content (the gate_state_hash
# fingerprint of src/ + test/ + build.zig*) need not re-run. `record_pass`
# appends `<FP> <name>` as each step passes; `--resume` skips lines already
# present. A fresh (non-resume) run truncates the ledger so it rebuilds; a
# content change flips FP so old lines never match (full re-validate). The
# ledger is gitignored scratch (`.dev/.gate_ledger`).
GATE_LEDGER="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/.dev/.gate_ledger"
GATE_FP="$(bash "${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/scripts/gate_state_hash.sh" 2>/dev/null || echo nofp)"
if (( ! RESUME )); then : > "$GATE_LEDGER" 2>/dev/null || true; fi
record_pass() { printf '%s %s\n' "$GATE_FP" "$1" >> "$GATE_LEDGER" 2>/dev/null || true; }
resume_done() { (( RESUME )) && grep -qxF "$GATE_FP $1" "$GATE_LEDGER" 2>/dev/null; }

# --- Steps ---

# Unit tests on BOTH backends. `zig build test` now defaults to vm (the
# production default, ADR-0070 flip); tree_walk (the differential oracle) is
# kept explicit so both backends retain unit coverage after the flip.
run_step "zig_build_test_vm"        "zig build test -Dwasm"
run_step "zig_build_test_tree_walk" "zig build test -Dwasm -Dbackend=tree_walk"
run_step "zone_check"           "bash scripts/zone_check.sh --gate"
run_step "surface_marker"       "bash scripts/check_surface_marker.sh --gate"
run_step "feature_keyword"      "bash scripts/check_feature_keyword.sh --gate"
run_step "host_interface"       "bash scripts/check_host_interface.sh --gate"
# Hard-fail: any src/**/*.zig with test{} blocks that is not
# reachable from src/main.zig via @import (= Zig 0.16 lazy-decl-
# analysis silently skips its tests). See zig_tips.md "Test
# discovery via @import" + scripts/check_test_reach.sh.
run_step "test_reach"           "bash scripts/check_test_reach.sh --gate"
run_step "e2e_reach"            "bash scripts/check_e2e_reach.sh --gate"
run_step "e2e_dup"              "bash scripts/check_e2e_dup.sh"
# Informational (no --gate): every D-NNN cited in source/docs must resolve
# to a debt.yaml row (kills phantom IDs), + prints the quality-loop-floor
# backlog so the F-010 loop sees it. Tech-debt consolidation 2026-05-31 /
# .dev/tech_debt_consolidation.md. Gate-promotion tracked in D-175.
run_step "debt_id_refs"         "bash scripts/check_debt_id_refs.sh --gate"

# Accepted clj-divergence ledger (.dev/accepted_divergences.yaml): every
# AD-NNN cites a justifying invariant + a pinning test, and COVERAGE.md
# points at the SSOT. Keeps the "NOT a bug" list a trust contract that
# cannot drift or accept-without-reason. Rule: accepted_divergences.md.
run_step "accepted_divergences" "bash scripts/check_accepted_divergences.sh --gate"

# zlinter no_deprecated gate (ADR-0003) — Mac-host only. zlinter is
# fetched via `zig fetch` against GitHub; OrbStack runs are network-
# free per .dev/orbstack_setup.md.
if [[ "$(uname -s)" == "Darwin" ]]; then
    run_step "zlinter"          "zig build lint -Dwasm -- --max-warnings 0"
fi

# Build the default (vm — production, ADR-0070 flip) cljw binary ONCE here,
# then tell the e2e scripts to skip their own `zig build` (each was a ~0.3s
# cache-hit × ~108 scripts ≈ 32s of redundant rebuilds + process spawns per
# gate). The 3 backend-forcing e2e (phase4_*) keep their own `-Dbackend=…`
# builds (which honour CLJW_OPT) and restore the DEFAULT (vm) at their end
# (bare `zig build`, default-following), so the shared binary stays the
# production default+CLJW_OPT for every guarded e2e — i.e. the e2e surface
# is exercised on vm, the production backend.
# Standalone e2e runs (env unset) still build normally — the guard is a
# no-op outside the gate.
#
# CLJW_OPT=ReleaseSafe: the e2e binary is OPTIMISED but keeps ALL safety
# checks (overflow / bounds / unreachable) so regressions are still
# caught — Debug-mode interpretation made compute-heavy e2e ~13x slower
# (e.g. transducer 8s -> 0.6s). Unit tests (zig_build_test above) stay
# Debug for the richest assertion diagnostics; they are a separate exe.
export CLJW_OPT="${CLJW_OPT:-ReleaseSafe}"
run_step "build_cljw"           "zig build -Dwasm -Doptimize=$CLJW_OPT"
export CLJW_SKIP_BUILD=1

# Loud guard for the silent perf cliff (D-385): the ~3200-spawn e2e suite
# runs ~100x slower on a Debug binary (~1.7s vs ~5ms cold-start) with NO
# failure. Refuse to enter e2e unless the shared binary is actually
# optimised. Size is the deterministic, load-independent signal here:
# ReleaseSafe ≈ 3.5 MB vs Debug ≈ 12.8 MB. If a future ReleaseSafe binary
# ever exceeds 8 MB, replace this heuristic with a semantic build-mode
# check (e.g. a `cljw --build-mode` introspection).
run_step "assert_e2e_releasesafe" 'mode=$(zig-out/bin/cljw --version 2>/dev/null | sed -nE "s/.*\((.*)\)/\1/p"); { [ -n "$mode" ] && [ "$mode" != Debug ]; } || { echo "    e2e binary build mode=${mode:-unknown} (CLJW_OPT='"$CLJW_OPT"') — Debug/unknown, not optimised. e2e would run ~100x slow; build_cljw must run every pass (NO_RESUME_STEPS). Refusing."; exit 1; }; echo "    e2e binary build mode: $mode"'

# clj-diff corpus regression (cljw-only replay of golden `;;=> …` pairs —
# no clj/network). Makes a "X/Y landed" discharge claim mechanically
# re-checkable (anti D-177 false-positive-discharge) + catches behaviour
# drift. See .claude/rules/clj_diff_sweep.md.
run_step "corpus_regression"   "bash scripts/check_corpus_regression.sh"

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
run_step "e2e_phase7_record_field_scope"     "bash test/e2e/phase7_record_field_scope.sh"
run_step "e2e_phase7_reify"                  "bash test/e2e/phase7_reify.sh"
run_step "e2e_phase7_method_dispatch"        "bash test/e2e/phase7_method_dispatch.sh"
run_step "e2e_phase7_polymorphic_extend"     "bash test/e2e/phase7_polymorphic_extend.sh"
run_step "e2e_phase7_extend_native_class"    "bash test/e2e/phase7_extend_native_class.sh"
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
run_step "e2e_phase14_json_options"          "bash test/e2e/phase14_json_options.sh"
run_step "e2e_phase9_csv"                    "bash test/e2e/phase9_csv.sh"
run_step "e2e_phase9_cli"                    "bash test/e2e/phase9_cli.sh"
run_step "e2e_phase9_exit_smoke"             "bash test/e2e/phase9_exit_smoke.sh"
run_step "e2e_phase10_pprint"                "bash test/e2e/phase10_pprint.sh"
run_step "e2e_phase14_pprint_dispatch"       "bash test/e2e/phase14_pprint_dispatch.sh"
run_step "e2e_phase14_cl_format"             "bash test/e2e/phase14_cl_format.sh"
run_step "e2e_phase10_exit_smoke"            "bash test/e2e/phase10_exit_smoke.sh"
# phase11_clojure_test retired: the D-099-era minimal `is`/`run-tests` surface it
# tested was replaced by the real clojure.test (D-227) — see e2e_phase15_clojure_test.
run_step "test_clj_tier_a"                   "bash test/clj/run_tier_a.sh"
run_step "e2e_phase11_exit_smoke"            "bash test/e2e/phase11_exit_smoke.sh"
run_step "e2e_phase13_exit_smoke"            "bash test/e2e/phase13_exit_smoke.sh"
run_step "e2e_phase14_catch_keyword"         "bash test/e2e/phase14_catch_keyword.sh"
run_step "e2e_phase14_catch_internal"        "bash test/e2e/phase14_catch_internal.sh"
run_step "e2e_phase14_binding"               "bash test/e2e/phase14_binding.sh"
run_step "e2e_phase14_with_context"          "bash test/e2e/phase14_with_context.sh"
run_step "e2e_phase14_user_throw"            "bash test/e2e/phase14_user_throw.sh"
run_step "e2e_phase14_collection_keys"       "bash test/e2e/phase14_collection_keys.sh"
run_step "e2e_phase14_key_val"               "bash test/e2e/phase14_key_val.sh"
run_step "e2e_phase14_multifn_introspect"    "bash test/e2e/phase14_multifn_introspect.sh"
run_step "e2e_phase14_auto_keyword"          "bash test/e2e/phase14_auto_keyword.sh"
run_step "e2e_phase14_data_diff"             "bash test/e2e/phase14_data_diff.sh"
run_step "e2e_phase14_eval"                  "bash test/e2e/phase14_eval.sh"
run_step "e2e_phase14_arity_parity"          "bash test/e2e/phase14_arity_parity.sh"
run_step "e2e_phase14_fn_macro"              "bash test/e2e/phase14_fn_macro.sh"
run_step "e2e_phase14_anon_fn_reader"        "bash test/e2e/phase14_anon_fn_reader.sh"
run_step "e2e_phase14_defmacro_user"         "bash test/e2e/phase14_defmacro_user.sh"
run_step "e2e_phase14_ns_directive"          "bash test/e2e/phase14_ns_directive.sh"
run_step "e2e_phase14_future_promise_delay"  "bash test/e2e/phase14_future_promise_delay.sh"
run_step "e2e_phase14_repl"                  "bash test/e2e/phase14_repl.sh"
run_step "e2e_phase14_nrepl"                 "bash test/e2e/phase14_nrepl.sh"
run_step "e2e_phase14_error_format"          "bash test/e2e/phase14_error_format.sh"
run_step "e2e_phase14_render_error"          "bash test/e2e/phase14_render_error.sh"
run_step "e2e_phase14_callable_print"        "bash test/e2e/phase14_callable_print.sh"
run_step "e2e_phase14_java_static_dispatch"  "bash test/e2e/phase14_java_static_dispatch.sh"
run_step "e2e_phase14_system_statics"        "bash test/e2e/phase14_system_statics.sh"
run_step "e2e_phase14_integer_statics"       "bash test/e2e/phase14_integer_statics.sh"
run_step "e2e_phase14_long_statics"          "bash test/e2e/phase14_long_statics.sh"
run_step "e2e_phase14_double_statics"        "bash test/e2e/phase14_double_statics.sh"
run_step "e2e_phase14_character_statics"     "bash test/e2e/phase14_character_statics.sh"
run_step "e2e_phase14_static_fields"         "bash test/e2e/phase14_static_fields.sh"
run_step "e2e_phase14_bignum_compare"        "bash test/e2e/phase14_bignum_compare.sh"
run_step "e2e_phase14_boolean_statics"       "bash test/e2e/phase14_boolean_statics.sh"
run_step "e2e_phase14_math_extra"            "bash test/e2e/phase14_math_extra.sh"
run_step "e2e_phase14_instance_member"       "bash test/e2e/phase14_instance_member.sh"
run_step "e2e_phase14_instance_deref_family" "bash test/e2e/phase14_instance_deref_family.sh"
run_step "e2e_phase14_def_meta_quote_value"  "bash test/e2e/phase14_def_meta_quote_value.sh"
run_step "e2e_phase14_math"                  "bash test/e2e/phase14_math.sh"
run_step "e2e_phase14_math_exact"            "bash test/e2e/phase14_math_exact.sh"
run_step "e2e_phase14_fn_recur"              "bash test/e2e/phase14_fn_recur.sh"
run_step "e2e_phase14_defn_docstring"        "bash test/e2e/phase14_defn_docstring.sh"
run_step "e2e_phase14_deftype"               "bash test/e2e/phase14_deftype.sh"
run_step "e2e_phase14_letfn"                 "bash test/e2e/phase14_letfn.sh"
run_step "e2e_phase14_math_transcendental" "bash test/e2e/phase14_math_transcendental.sh"
run_step "e2e_phase14_destructure"           "bash test/e2e/phase14_destructure.sh"
run_step "e2e_phase14_map_string_keys"       "bash test/e2e/phase14_map_string_keys.sh"
run_step "e2e_phase14_float_print"           "bash test/e2e/phase14_float_print.sh"
run_step "e2e_phase14_comp_juxt_partition"   "bash test/e2e/phase14_comp_juxt_partition.sh"
run_step "e2e_phase14_map_complement_vector" "bash test/e2e/phase14_map_complement_vector.sh"
run_step "e2e_phase14_seq_core_batch"        "bash test/e2e/phase14_seq_core_batch.sh"
run_step "e2e_phase14_merge_partition_by"    "bash test/e2e/phase14_merge_partition_by.sh"
run_step "e2e_phase14_threading_macros"      "bash test/e2e/phase14_threading_macros.sh"
run_step "e2e_phase14_thread_runtime"        "bash test/e2e/phase14_thread_runtime.sh"
run_step "e2e_phase14_arraylist"             "bash test/e2e/phase14_arraylist.sh"
run_step "e2e_phase14_hashmap"               "bash test/e2e/phase14_hashmap.sh"
run_step "e2e_phase14_date_ctor"             "bash test/e2e/phase14_date_ctor.sh"
run_step "e2e_phase14_self_seq_print"        "bash test/e2e/phase14_self_seq_print.sh"
run_step "e2e_phase14_count_walk"            "bash test/e2e/phase14_count_walk.sh"
run_step "e2e_phase14_sequential_equal"      "bash test/e2e/phase14_sequential_equal.sh"
run_step "e2e_phase14_seq_key_hash"          "bash test/e2e/phase14_seq_key_hash.sh"
run_step "e2e_phase14_with_in_str"           "bash test/e2e/phase14_with_in_str.sh"
run_step "e2e_phase14_lisp_string_reader"    "bash test/e2e/phase14_lisp_string_reader.sh"
run_step "e2e_phase14_qualified_deftype"     "bash test/e2e/phase14_qualified_deftype.sh"
run_step "e2e_phase14_string_getbytes"       "bash test/e2e/phase14_string_getbytes.sh"
run_step "e2e_phase14_some_doto"             "bash test/e2e/phase14_some_doto.sh"
run_step "e2e_phase14_iteration_macros"      "bash test/e2e/phase14_iteration_macros.sh"
run_step "e2e_phase14_case"                  "bash test/e2e/phase14_case.sh"
run_step "e2e_phase14_condp"                 "bash test/e2e/phase14_condp.sh"
run_step "e2e_phase14_println_stdout"        "bash test/e2e/phase14_println_stdout.sh"
run_step "e2e_phase14_fn_combinators"        "bash test/e2e/phase14_fn_combinators.sh"
run_step "e2e_phase14_when_if_not"          "bash test/e2e/phase14_when_if_not.sh"
run_step "e2e_phase14_assert_distinct"      "bash test/e2e/phase14_assert_distinct.sh"
run_step "e2e_phase14_partition_all"       "bash test/e2e/phase14_partition_all.sh"
run_step "e2e_phase14_not_eq_run"          "bash test/e2e/phase14_not_eq_run.sh"
run_step "e2e_phase14_peek_pop"            "bash test/e2e/phase14_peek_pop.sh"
run_step "e2e_phase14_find"                "bash test/e2e/phase14_find.sh"
run_step "e2e_phase14_int_char"            "bash test/e2e/phase14_int_char.sh"
run_step "e2e_phase14_char_print"          "bash test/e2e/phase14_char_print.sh"
run_step "e2e_phase14_subvec"              "bash test/e2e/phase14_subvec.sh"
run_step "e2e_phase14_bounded_count"       "bash test/e2e/phase14_bounded_count.sh"
run_step "e2e_phase14_lazy_cat"            "bash test/e2e/phase14_lazy_cat.sh"
run_step "e2e_phase14_tree_seq"            "bash test/e2e/phase14_tree_seq.sh"
run_step "e2e_phase14_rand"                "bash test/e2e/phase14_rand.sh"
run_step "e2e_phase14_shuffle"             "bash test/e2e/phase14_shuffle.sh"
run_step "e2e_phase14_float_div"           "bash test/e2e/phase14_float_div.sh"
run_step "e2e_phase14_num_predicates"      "bash test/e2e/phase14_num_predicates.sh"
run_step "e2e_phase14_ratio_accessors"     "bash test/e2e/phase14_ratio_accessors.sh"
run_step "e2e_phase14_rationalize"         "bash test/e2e/phase14_rationalize.sh"
run_step "e2e_phase14_ratio_arith"         "bash test/e2e/phase14_ratio_arith.sh"
run_step "e2e_phase14_quot_rem_mod_tower"  "bash test/e2e/phase14_quot_rem_mod_tower.sh"
run_step "e2e_phase14_long_num_bitandnot"   "bash test/e2e/phase14_long_num_bitandnot.sh"
run_step "e2e_phase14_parse"                "bash test/e2e/phase14_parse.sh"
run_step "e2e_phase14_double_float"        "bash test/e2e/phase14_double_float.sh"
run_step "e2e_phase14_reductions_splitat"  "bash test/e2e/phase14_reductions_splitat.sh"
run_step "e2e_phase14_counted_reversible"  "bash test/e2e/phase14_counted_reversible.sh"
run_step "e2e_phase14_doseq"                "bash test/e2e/phase14_doseq.sh"
run_step "e2e_phase14_for"                  "bash test/e2e/phase14_for.sh"
run_step "e2e_phase14_format"               "bash test/e2e/phase14_format.sh"
run_step "e2e_phase14_bit_ops"              "bash test/e2e/phase14_bit_ops.sh"
run_step "e2e_phase14_string_indexed"       "bash test/e2e/phase14_string_indexed.sh"
run_step "e2e_phase14_namespaced_maps"      "bash test/e2e/phase14_namespaced_maps.sh"
run_step "e2e_phase14_atom_watch"           "bash test/e2e/phase14_atom_watch.sh"
run_step "e2e_phase14_parallel_seq"         "bash test/e2e/phase14_parallel_seq.sh"
run_step "e2e_phase14_alter_var_root"       "bash test/e2e/phase14_alter_var_root.sh"
run_step "e2e_phase14_syntax_quote"         "bash test/e2e/phase14_syntax_quote.sh"
run_step "e2e_phase14_with_redefs"          "bash test/e2e/phase14_with_redefs.sh"
run_step "e2e_phase15_namespace"            "bash test/e2e/phase15_namespace.sh"
run_step "e2e_phase15_dynamic_var"          "bash test/e2e/phase15_dynamic_var.sh"
run_step "e2e_phase15_clojure_test"         "bash test/e2e/phase15_clojure_test.sh"
run_step "e2e_phase15_clojure_test_output"  "bash test/e2e/phase15_clojure_test_output.sh"
run_step "e2e_phase15_java_time_instant"    "bash test/e2e/phase15_java_time_instant.sh"
run_step "e2e_phase15_java_time_duration"   "bash test/e2e/phase15_java_time_duration.sh"
run_step "e2e_phase15_java_time_local_date_time"  "bash test/e2e/phase15_java_time_local_date_time.sh"
run_step "e2e_phase15_java_time_local_date"  "bash test/e2e/phase15_java_time_local_date.sh"
run_step "e2e_phase15_java_time_compare"     "bash test/e2e/phase15_java_time_compare.sh"
run_step "e2e_phase15_java_time_sort"       "bash test/e2e/phase15_java_time_sort.sh"
run_step "e2e_phase15_require_fs"           "bash test/e2e/phase15_require_fs.sh"
run_step "e2e_phase15_use_refer_all"        "bash test/e2e/phase15_use_refer_all.sh"
run_step "e2e_phase15_use_libspec_filter"   "bash test/e2e/phase15_use_libspec_filter.sh"
run_step "e2e_phase15_system_property"      "bash test/e2e/phase15_system_property.sh"
run_step "e2e_phase15_set_bang"             "bash test/e2e/phase15_set_bang.sh"
run_step "e2e_phase15_stm_dosync"           "bash test/e2e/phase15_stm_dosync.sh"
run_step "e2e_phase16_locking"              "bash test/e2e/phase16_locking.sh"
run_step "e2e_phase16_agent"                "bash test/e2e/phase16_agent.sh"
run_step "e2e_phase16_concurrency_stress"   "bash test/e2e/phase16_concurrency_stress.sh"
run_step "e2e_phase16_http_server"          "bash test/e2e/phase16_http_server.sh"
run_step "e2e_phase16_http_client"          "bash test/e2e/phase16_http_client.sh"
run_step "e2e_phase16_eval_budget"          "bash test/e2e/phase16_eval_budget.sh"
run_step "e2e_phase16_file_io_errors"       "bash test/e2e/phase16_file_io_errors.sh"
run_step "e2e_phase16_repl_classpath"       "bash test/e2e/phase16_repl_classpath.sh"
run_step "e2e_phase16_extend_via_metadata"  "bash test/e2e/phase16_extend_via_metadata.sh"
run_step "e2e_phase16_fs_jail"              "bash test/e2e/phase16_fs_jail.sh"
run_step "e2e_phase16_java_io_file"         "bash test/e2e/phase16_java_io_file.sh"
run_step "e2e_phase16_clojure_java_io"      "bash test/e2e/phase16_clojure_java_io.sh"
run_step "e2e_phase16_host_stream"          "bash test/e2e/phase16_host_stream.sh"
run_step "e2e_phase16_clojure_java_io_streams" "bash test/e2e/phase16_clojure_java_io_streams.sh"
run_step "e2e_phase16_clojure_java_io_copy" "bash test/e2e/phase16_clojure_java_io_copy.sh"
run_step "e2e_phase16_cljw_json_fs"         "bash test/e2e/phase16_cljw_json_fs.sh"
run_step "e2e_phase16_tokenizer_long_input" "bash test/e2e/phase16_tokenizer_long_input.sh"
# Wasm-FFI execution e2e — now part of the DEFAULT full gate (F-001 amended
# 2026-06-12: zwasm v2 is complete, so the gate builds `-Dwasm` throughout and
# exercises the headline FFI path). They reuse the shared -Dwasm binary
# (CLJW_SKIP_BUILD), so no per-step rebuild. On a host where `zig build -Dwasm`
# cannot resolve zwasm, build_cljw fails first — wasm is a gate prerequisite now.
run_step "e2e_phase16_wasm_ffi"             "bash test/e2e/phase16_wasm_ffi.sh"
run_step "e2e_phase16_wasm_run"             "bash test/e2e/phase16_wasm_run.sh"
run_step "e2e_phase16_wasm_component"       "bash test/e2e/phase16_wasm_component.sh"
run_step "e2e_phase16_wasm_require_component" "bash test/e2e/phase16_wasm_require_component.sh"
run_step "e2e_phase15_for_while"            "bash test/e2e/phase15_for_while.sh"
run_step "e2e_phase15_ns_import"            "bash test/e2e/phase15_ns_import.sh"
run_step "e2e_phase15_dot_form"             "bash test/e2e/phase15_dot_form.sh"
run_step "e2e_phase15_var_get_set"          "bash test/e2e/phase15_var_get_set.sh"
run_step "e2e_phase15_with_local_vars"      "bash test/e2e/phase15_with_local_vars.sh"
run_step "e2e_phase15_campaign_keywords"    "bash test/e2e/phase15_campaign_keywords.sh"
run_step "e2e_phase15_macro_literals"       "bash test/e2e/phase15_macro_literals.sh"
run_step "e2e_phase15_alias"                "bash test/e2e/phase15_alias.sh"
run_step "e2e_phase15_aliased_macro"        "bash test/e2e/phase15_aliased_macro.sh"
run_step "e2e_phase15_dotdot"               "bash test/e2e/phase15_dotdot.sh"
run_step "e2e_phase15_clojure_template"     "bash test/e2e/phase15_clojure_template.sh"
run_step "e2e_phase15_class_methods"        "bash test/e2e/phase15_class_methods.sh"
run_step "e2e_phase15_deferred_host_ref"    "bash test/e2e/phase15_deferred_host_ref.sh"
run_step "e2e_phase15_defmulti_defmethod"   "bash test/e2e/phase15_defmulti_defmethod.sh"
run_step "e2e_phase15_with_open"            "bash test/e2e/phase15_with_open.sh"
run_step "e2e_phase15_defprotocol_docstring" "bash test/e2e/phase15_defprotocol_docstring.sh"
run_step "e2e_phase15_marker_protocol"      "bash test/e2e/phase15_marker_protocol.sh"
run_step "e2e_phase15_ns_binding_roundtrip" "bash test/e2e/phase15_ns_binding_roundtrip.sh"
run_step "e2e_phase15_ns_runtime_fns"       "bash test/e2e/phase15_ns_runtime_fns.sh"
run_step "e2e_phase15_defmethod_destructure" "bash test/e2e/phase15_defmethod_destructure.sh"
run_step "e2e_phase15_new_ctor"             "bash test/e2e/phase15_new_ctor.sh"
run_step "e2e_phase15_import_macro"         "bash test/e2e/phase15_import_macro.sh"
run_step "e2e_phase15_require_runtime_fn"   "bash test/e2e/phase15_require_runtime_fn.sh"
run_step "e2e_phase15_class_as_value"       "bash test/e2e/phase15_class_as_value.sh"
run_step "e2e_phase15_pr_newline"           "bash test/e2e/phase15_pr_newline.sh"
run_step "e2e_phase15_ns_docstring"         "bash test/e2e/phase15_ns_docstring.sh"
run_step "e2e_phase15_reader_conditional"   "bash test/e2e/phase15_reader_conditional.sh"
run_step "e2e_phase15_persistent_queue"     "bash test/e2e/phase15_persistent_queue.sh"
run_step "e2e_phase15_clojure_stacktrace"   "bash test/e2e/phase15_clojure_stacktrace.sh"
run_step "e2e_phase15_clojure_uuid"         "bash test/e2e/phase15_clojure_uuid.sh"
run_step "e2e_phase15_clojure_instant"      "bash test/e2e/phase15_clojure_instant.sh"
run_step "e2e_phase15_clojure_test_tap"     "bash test/e2e/phase15_clojure_test_tap.sh"
run_step "e2e_phase16_gc_torture"           "bash test/e2e/phase16_gc_torture.sh"
run_step "e2e_phase14_cljw_build"            "bash test/e2e/phase14_cljw_build.sh"
run_step "e2e_phase14_core_cluster"          "bash test/e2e/phase14_core_cluster.sh"
run_step "e2e_phase14_print_family"          "bash test/e2e/phase14_print_family.sh"
run_step "e2e_phase14_var_special"           "bash test/e2e/phase14_var_special.sh"
run_step "e2e_phase14_deps_edn"              "bash test/e2e/phase14_deps_edn.sh"
run_step "e2e_phase14_deps_run_mode"         "bash test/e2e/phase14_deps_run_mode.sh"
run_step "e2e_phase14_typed_instance_metadata" "bash test/e2e/phase14_typed_instance_metadata.sh"
run_step "e2e_phase9_record_extmap"          "bash test/e2e/phase9_record_extmap.sh"
run_step "e2e_phase14_redef"                 "bash test/e2e/phase14_redef.sh"
run_step "e2e_phase14_var_metadata"          "bash test/e2e/phase14_var_metadata.sh"
run_step "e2e_phase14_defn_meta"             "bash test/e2e/phase14_defn_meta.sh"
run_step "e2e_phase14_empty_list"            "bash test/e2e/phase14_empty_list.sh"
run_step "e2e_phase14_object_methods"        "bash test/e2e/phase14_object_methods.sh"
run_step "e2e_phase14_map_entry"             "bash test/e2e/phase14_map_entry.sh"
run_step "e2e_phase14_inst_literal"          "bash test/e2e/phase14_inst_literal.sh"
run_step "e2e_phase14_exception_ctor"        "bash test/e2e/phase14_exception_ctor.sh"
run_step "e2e_phase14_doc"                   "bash test/e2e/phase14_doc.sh"
run_step "e2e_phase14_coll_helpers"          "bash test/e2e/phase14_coll_helpers.sh"
run_step "e2e_phase14_map_helpers"           "bash test/e2e/phase14_map_helpers.sh"
run_step "e2e_phase14_hamt_map"              "bash test/e2e/phase14_hamt_map.sh"
run_step "e2e_phase14_ifn_callable"          "bash test/e2e/phase14_ifn_callable.sh"
run_step "e2e_phase14_atom"                  "bash test/e2e/phase14_atom.sh"
run_step "e2e_phase14_hash_gensym"           "bash test/e2e/phase14_hash_gensym.sh"
run_step "e2e_phase14_volatile"              "bash test/e2e/phase14_volatile.sh"
run_step "e2e_phase14_comparator"            "bash test/e2e/phase14_comparator.sh"
run_step "e2e_phase14_vector_keys"           "bash test/e2e/phase14_vector_keys.sh"
run_step "e2e_phase14_memoize"               "bash test/e2e/phase14_memoize.sh"
run_step "e2e_phase14_metadata"              "bash test/e2e/phase14_metadata.sh"
run_step "e2e_phase14_symbol_metadata"       "bash test/e2e/phase14_symbol_metadata.sh"
run_step "e2e_phase14_deftype_collection_base" "bash test/e2e/phase14_deftype_collection_base.sh"
run_step "e2e_phase14_deftype_inherited_method" "bash test/e2e/phase14_deftype_inherited_method.sh"
run_step "e2e_phase14_reify_remap" "bash test/e2e/phase14_reify_remap.sh"
run_step "e2e_phase14_deftype_sorted" "bash test/e2e/phase14_deftype_sorted.sh"
run_step "e2e_phase14_deftype_kvreduce_blocking" "bash test/e2e/phase14_deftype_kvreduce_blocking.sh"
run_step "e2e_phase14_unicode_case" "bash test/e2e/phase14_unicode_case.sh"
run_step "e2e_phase14_deftype_transient_family" "bash test/e2e/phase14_deftype_transient_family.sh"
run_step "e2e_phase14_print_method"          "bash test/e2e/phase14_print_method.sh"
run_step "e2e_phase14_member_on_native"      "bash test/e2e/phase14_member_on_native.sh"
run_step "e2e_phase14_java_method_grouping"  "bash test/e2e/phase14_java_method_grouping.sh"
run_step "e2e_phase14_fn_prepost"            "bash test/e2e/phase14_fn_prepost.sh"
run_step "e2e_phase14_deftype_ideref"        "bash test/e2e/phase14_deftype_ideref.sh"
run_step "e2e_phase14_equality"              "bash test/e2e/phase14_equality.sh"
run_step "e2e_phase14_realworld_program"     "bash test/e2e/phase14_realworld_program.sh"
run_step "e2e_phase14_dedup_group"           "bash test/e2e/phase14_dedup_group.sh"
run_step "e2e_phase14_seq_helpers2"          "bash test/e2e/phase14_seq_helpers2.sh"
run_step "e2e_phase14_reduce_helpers"        "bash test/e2e/phase14_reduce_helpers.sh"
run_step "e2e_phase14_accessors"             "bash test/e2e/phase14_accessors.sh"
run_step "e2e_phase14_compare"               "bash test/e2e/phase14_compare.sh"
run_step "e2e_phase14_sort"                  "bash test/e2e/phase14_sort.sh"
run_step "e2e_phase14_sorted"                "bash test/e2e/phase14_sorted.sh"
run_step "e2e_phase14_transducers"           "bash test/e2e/phase14_transducers.sh"
run_step "e2e_phase14_hierarchy"             "bash test/e2e/phase14_hierarchy.sh"
run_step "e2e_phase14_class_type"            "bash test/e2e/phase14_class_type.sh"
run_step "e2e_phase14_deftype_object"        "bash test/e2e/phase14_deftype_object.sh"
run_step "e2e_phase14_deftype_mutable"       "bash test/e2e/phase14_deftype_mutable.sh"
run_step "e2e_phase14_arrays"                "bash test/e2e/phase14_arrays.sh"
run_step "e2e_phase14_random"                "bash test/e2e/phase14_random.sh"
run_step "e2e_phase14_uri"                   "bash test/e2e/phase14_uri.sh"
run_step "e2e_phase14_extend_protocol_targets" "bash test/e2e/phase14_extend_protocol_targets.sh"
run_step "e2e_phase14_extend_fn"             "bash test/e2e/phase14_extend_fn.sh"
run_step "e2e_phase14_deftype_imeta"         "bash test/e2e/phase14_deftype_imeta.sh"
run_step "e2e_phase14_deftype_iseq"          "bash test/e2e/phase14_deftype_iseq.sh"
run_step "e2e_phase14_deftype_indexed"       "bash test/e2e/phase14_deftype_indexed.sh"
run_step "e2e_phase14_deftype_ireduce"       "bash test/e2e/phase14_deftype_ireduce.sh"
run_step "e2e_phase14_catch_fqcn_exceptions" "bash test/e2e/phase14_catch_fqcn_exceptions.sh"
run_step "e2e_phase14_destructure_fn"        "bash test/e2e/phase14_destructure_fn.sh"
run_step "e2e_phase14_deftype_cross_ns_import" "bash test/e2e/phase14_deftype_cross_ns_import.sh"
run_step "e2e_phase14_prefix_list_libspec"   "bash test/e2e/phase14_prefix_list_libspec.sh"
run_step "e2e_phase14_regex_lookahead"       "bash test/e2e/phase14_regex_lookahead.sh"
run_step "e2e_phase14_re_matcher"            "bash test/e2e/phase14_re_matcher.sh"
run_step "e2e_phase14_locale"                "bash test/e2e/phase14_locale.sh"
run_step "e2e_phase14_short_byte"            "bash test/e2e/phase14_short_byte.sh"
run_step "e2e_phase14_syntax_quote_exclude"   "bash test/e2e/phase14_syntax_quote_exclude.sh"
run_step "e2e_phase14_hex_bigint"             "bash test/e2e/phase14_hex_bigint.sh"
run_step "e2e_phase14_ns_form_leniency"       "bash test/e2e/phase14_ns_form_leniency.sh"
run_step "e2e_phase14_cljc_libspec"          "bash test/e2e/phase14_cljc_libspec.sh"
run_step "e2e_phase14_empty_catch"           "bash test/e2e/phase14_empty_catch.sh"
run_step "e2e_phase14_extend_type_nil"       "bash test/e2e/phase14_extend_type_nil.sh"
run_step "e2e_phase14_deftype_method_lowering" "bash test/e2e/phase14_deftype_method_lowering.sh"
run_step "e2e_phase14_clojure_lang_util"     "bash test/e2e/phase14_clojure_lang_util.sh"
run_step "e2e_phase14_opaque_host_class"     "bash test/e2e/phase14_opaque_host_class.sh"
run_step "e2e_phase14_bigdecimal_setscale"   "bash test/e2e/phase14_bigdecimal_setscale.sh"
run_step "e2e_phase14_ratio_interop"        "bash test/e2e/phase14_ratio_interop.sh"
run_step "e2e_phase14_class_names"           "bash test/e2e/phase14_class_names.sh"
run_step "e2e_phase14_pattern_quote"         "bash test/e2e/phase14_pattern_quote.sh"
run_step "e2e_phase14_var_resolve"           "bash test/e2e/phase14_var_resolve.sh"
run_step "e2e_phase14_biginteger"            "bash test/e2e/phase14_biginteger.sh"
run_step "e2e_phase14_format_char_int"       "bash test/e2e/phase14_format_char_int.sh"
run_step "e2e_phase14_throwable_map"         "bash test/e2e/phase14_throwable_map.sh"
run_step "e2e_phase14_defmacro_destructure"  "bash test/e2e/phase14_defmacro_destructure.sh"
run_step "e2e_phase14_read_string"           "bash test/e2e/phase14_read_string.sh"
run_step "e2e_phase14_range_indexed"         "bash test/e2e/phase14_range_indexed.sh"
run_step "e2e_phase14_lazy_seq"              "bash test/e2e/phase14_lazy_seq.sh"
run_step "e2e_phase14_lazy_map"              "bash test/e2e/phase14_lazy_map.sh"
run_step "e2e_phase14_chunked_seq"           "bash test/e2e/phase14_chunked_seq.sh"
run_step "e2e_phase14_lazy_seq_cycle3"       "bash test/e2e/phase14_lazy_seq_cycle3.sh"
run_step "e2e_phase14_lazy_seq_cycle4"       "bash test/e2e/phase14_lazy_seq_cycle4.sh"
run_step "e2e_phase14_tagged_literal"        "bash test/e2e/phase14_tagged_literal.sh"
run_step "e2e_phase14_print_control"         "bash test/e2e/phase14_print_control.sh"
run_step "e2e_phase14_uuid_literal"          "bash test/e2e/phase14_uuid_literal.sh"
run_step "e2e_phase14_clojure_lang_coll_hash" "bash test/e2e/phase14_clojure_lang_coll_hash.sh"
run_step "e2e_phase14_multipair_assoc_extend" "bash test/e2e/phase14_multipair_assoc_extend.sh"
run_step "e2e_phase14_deftype_equiv"          "bash test/e2e/phase14_deftype_equiv.sh"
run_step "e2e_phase14_deftype_key_hash"       "bash test/e2e/phase14_deftype_key_hash.sh"
run_step "e2e_phase14_instaparse_substrate"   "bash test/e2e/phase14_instaparse_substrate.sh"
run_step "e2e_phase14_exit_smoke"            "bash test/e2e/phase14_exit_smoke.sh"
run_step "e2e_phase14_text_writer"           "bash test/e2e/phase14_text_writer.sh"
run_step "e2e_phase14_text_reader"           "bash test/e2e/phase14_text_reader.sh"

# Informational scans (ADR-0024). Phase 5+ they become blocking.
run_step "scan_catalog_only"   "bash scripts/scan_catalog_only.sh" optional
run_step "scan_panic_audit"    "bash scripts/scan_panic_audit.sh"  optional

# Bench is no longer run in the gate (user-directed 2026-06-11): the Phase-1
# `bench/quick.sh` + `bench/quick_baseline.txt` rough-baseline machinery has
# served its role and is retired. Perf is now measured on demand via
# `bench/compare_langs.sh` (cross-language) + `bench/run_bench.sh` (cljw-only),
# never inside the gate. (Retired: bench_quick, bench_regression.)

# Future suites (uncomment as their phase lands):
#   run_step "diff_runner"  "zig build test -Dtest-filter='differential cases'"
#   run_step "test_clj"     "bash scripts/run_clj_tests.sh"  # Phase 11
#   run_step "tier_check"   "bash scripts/tier_check.sh"     # Phase 14

# --- Summary ---

if (( LIST_ONLY )); then
    exit 0
fi

# Backstop for the silent perf cliff (D-385): re-assert the shared binary is
# STILL optimised right before the expensive parallel pool. assert_e2e_releasesafe
# ran right after build_cljw, but a later serial step that does a bare `zig build`
# (Debug) — the test_clj_tier_a class of bug — could have reverted it since. Catch
# it here so the ~3200-spawn pool never runs ~100x slow on Debug.
_pool_mode=$(zig-out/bin/cljw --version 2>/dev/null | sed -nE 's/.*\((.*)\)/\1/p')
if [ -z "$_pool_mode" ] || [ "$_pool_mode" = "Debug" ]; then
    echo "==> FATAL: e2e binary build mode=${_pool_mode:-unknown} before the parallel pool" >&2
    echo "    — a step ran a bare 'zig build' (Debug). Aborting; the pool would run ~100x slow (D-385)." >&2
    exit 1
fi

# Drain the deferred functional-e2e pool (no-op under --serial-e2e, where
# they already ran inline).
flush_e2e_queue

if print_summary; then
    if (( SMOKE_MODE )); then
        # ADR-0107: a green smoke stamps .dev/.smoke_pass (the per-commit
        # authorization fingerprint). It does NOT touch .gate_pass or reset the
        # batch counter — only a full gate does that. The commit hook consumes a
        # batch slot per smoke-authorized commit and forces a full gate at the
        # ceiling.
        bash scripts/gate_state_hash.sh > .dev/.smoke_pass 2>/dev/null || true
    elif [[ -z "$ONLY_STEPS" && -z "$SKIP_STEPS" ]]; then
        # On a FULL green gate: record the verified source-state fingerprint so
        # scripts/check_gate_cadence.sh can authorise the matching commit, and
        # clear the batch counter — a full green gate validates everything up to
        # now, so the batch restarts (ADR-0107 / gate_cadence.md). A partial
        # (--only/--skip) run must not stamp either.
        bash scripts/gate_state_hash.sh > .dev/.gate_pass 2>/dev/null || true
        echo 0 > .dev/.gate_cadence 2>/dev/null || true
    fi
else
    exit 1
fi
