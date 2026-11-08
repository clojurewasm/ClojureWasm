#!/usr/bin/env bash
# scripts/check_entrypoint_surface.sh — CLI entry-point classpath parity guard.
#
# Born from Discussion #13: D-322 landed filesystem-classpath resolution on the
# terminal REPL, and `cljw nrepl` was not carried along — the one entry point
# where the user is CERTAIN to be on a project was the only one that could not
# `(require '[my.lib])`. The bug class is "a new (or overlooked) entry point
# silently misses the shared classpath contract". This guard makes that class
# fail the gate instead of waiting for a field report:
#
#   1. Extract the subcommand set from src/app/cli.zig's dispatch
#      (`std.mem.eql(u8, first, "<name>")`).
#   2. Two-sided set equality against the lists below — an EXTRA subcommand
#      (someone added one) and a MISSING subcommand (someone renamed/refactored
#      the dispatch idiom) both fail, forcing a conscious decision here.
#   3. Every EVAL subcommand's dispatch branch must reach the shared classpath
#      resolution (resolveClasspath / resolveDefaultClasspath / splitClasspath).
#   4. The default (non-subcommand) path — dispatchArgsRest — must too.
#   5. A vacuous extraction (< MIN_SUBCOMMANDS) fails: if the dispatch idiom
#      changes, this script must be re-taught, not silently pass.
#
# Adding a subcommand: EVAL_SUBCOMMANDS if it evaluates user code (it must then
# call the shared resolver AND join the classpath e2e coverage —
# test/e2e/phase16_repl_classpath.sh / phase14_nrepl_classpath.sh /
# phase14_cljw_build.sh are the per-entry rung owners); EXEMPT_SUBCOMMANDS only
# if it never evaluates user code (say why in the list).
#
# Modes: no args = gate (exit 1 on violation). Runs in <1s; part of the
# per-commit smoke core.

set -euo pipefail
cd "$(dirname "$0")/.."

CLI=src/app/cli.zig
MIN_SUBCOMMANDS=4

# Entry points that evaluate user code — each must resolve the classpath.
EVAL_SUBCOMMANDS=(repl nrepl build)
# render-error: decodes a CLJW_ERROR_LOG EDN event log; never evaluates code.
EXEMPT_SUBCOMMANDS=(render-error)

fail=0

# --- 1+2: extract the dispatch's subcommand set, compare two-sided ---
found=$(grep -oE 'std\.mem\.eql\(u8, first, "[a-z-]+"\)' "$CLI" \
    | sed -E 's/.*"([a-z-]+)".*/\1/' | sort -u)
found_n=$(grep -c . <<<"$found" || true)

if [ "$found_n" -lt "$MIN_SUBCOMMANDS" ]; then
    echo "check_entrypoint_surface: extracted only $found_n subcommand(s) from $CLI (< $MIN_SUBCOMMANDS)."
    echo "  The dispatch idiom likely changed — re-teach the extraction in this script."
    exit 1
fi

expected=$(printf '%s\n' "${EVAL_SUBCOMMANDS[@]}" "${EXEMPT_SUBCOMMANDS[@]}" | sort -u)
if [ "$found" != "$expected" ]; then
    echo "check_entrypoint_surface: subcommand set drift in $CLI."
    echo "  dispatch has:   $(echo $found)"
    echo "  script expects: $(echo $expected)"
    echo "  A NEW subcommand must be classified here: EVAL_SUBCOMMANDS (evaluates"
    echo "  user code -> must call the shared classpath resolver + join the"
    echo "  classpath e2e coverage) or EXEMPT_SUBCOMMANDS (never evaluates code)."
    fail=1
fi

# --- 3: every eval subcommand's branch reaches the shared resolver ---
# A branch spans from its `eql(u8, first, "<name>")` line to the next
# subcommand test (or the dispatchArgsRest fall-through).
for sc in "${EVAL_SUBCOMMANDS[@]}"; do
    branch=$(awk -v name="\"$sc\"" '
        index($0, "std.mem.eql(u8, first, " name ")") { on = 1 }
        on && (index($0, "std.mem.eql(u8, first,") && !index($0, name)) { exit }
        on && index($0, "dispatchArgsRest(") { exit }
        on { print }
    ' "$CLI")
    if ! grep -qE 'resolveClasspath|resolveDefaultClasspath|splitClasspath' <<<"$branch"; then
        echo "check_entrypoint_surface: subcommand '$sc' does not reach the shared"
        echo "  classpath resolution (resolveClasspath/resolveDefaultClasspath/splitClasspath)."
        echo "  This is the Discussion-#13 bug shape (nrepl ignored -cp/\$CLJW_PATH)."
        fail=1
    fi
done

# --- 3b: each eval subcommand's --help line advertises -cp. The help text is
# externally consumed: at least one editor integration probes `cljw --help`
# for `-cp` on the nrepl line to detect a classpath-capable build (Discussion
# #13, 2026-08-11 confirmation reply). A help line that stops advertising -cp
# silently breaks that capability detection even if the flag still works.
for sc in "${EVAL_SUBCOMMANDS[@]}"; do
    # `sed -n 1p` rather than `head -1`: head closes the pipe on its Nth line,
    # and grep takes SIGPIPE (check_epipe_head.sh gates this).
    help_line=$(grep -F "\\  $sc " "$CLI" | sed -n 1p || true)
    if [ -z "$help_line" ] || ! grep -q -- <<<"$help_line" '-cp'; then
        echo "check_entrypoint_surface: --help line for '$sc' is missing or does not advertise -cp."
        echo "  External integrations probe \`cljw --help\` for -cp capability detection."
        fail=1
    fi
done

# --- 3c: every path that evaluates a stream of top-level user forms must go
# through the shared top-level driver, not analyze+eval each form itself.
# Discussion #14: `eval_session.evalSource` (backing `repl` AND `nrepl`) and
# `builder.zig` (backing `cljw build`) each analysed a whole top-level `(do …)`
# before running any of it, so a `require` beside its first use failed —
# D-374's unroll had only ever reached `runner.runSource`. Sites are listed
# rather than discovered because "evaluates a form STREAM" is not greppable;
# adding a new one means adding it here.
EVAL_STREAM_SITES=(
    "src/app/eval_session.zig"   # repl + nrepl
    "src/app/runner.zig"         # script file / -e / stdin
    "src/app/builder.zig"        # cljw build (enumerates leaves: needs a chunk each)
    "src/lang/bootstrap.zig"     # bundled .clj loading
)
for site in "${EVAL_STREAM_SITES[@]}"; do
    if [ ! -f "$site" ]; then
        echo "check_entrypoint_surface: eval-stream site '$site' no longer exists — re-teach the list."
        fail=1
    elif ! grep -qE 'driver\.(evalTopLevelForm|topLevelLeaves)\(' "$site"; then
        echo "check_entrypoint_surface: '$site' evaluates top-level forms without the shared"
        echo "  top-level driver (driver.evalTopLevelForm / driver.topLevelLeaves)."
        echo "  This is the Discussion-#14 bug shape (a top-level \`do\` not unrolled)."
        fail=1
    fi
done

# --- 4: the default (file / -e / bare) path resolves the classpath too ---
# The slice is captured first so an EMPTY extraction is distinguishable from a
# non-resolving one. Both used to render as the same sentence and the same exit
# 1, so a run where the extraction simply produced nothing accused the source of
# a violation it did not have (observed 2026-08-31: this step failed inside a
# smoke run and passed standalone on the identical tree, while
# `fn dispatchArgsRest(` was present and its slice reached a resolver 8 times).
# Section 1 already guards its own extraction against vacuity; this is the same
# discipline — a broken extraction must be re-taught, not reported as drift.
rest=$(awk '/fn dispatchArgsRest\(/,0' "$CLI")
if [ -z "$rest" ]; then
    echo "check_entrypoint_surface: could not extract the dispatchArgsRest slice from $CLI."
    echo "  Either the fn was renamed (re-teach this script) or the extraction itself failed."
    echo "  This is NOT a classpath finding — do not 'fix' $CLI on the strength of it."
    fail=1
elif ! grep -qE 'resolveClasspath|resolveDefaultClasspath|splitClasspath' <<<"$rest"; then
    echo "check_entrypoint_surface: dispatchArgsRest no longer reaches the shared classpath resolution."
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "check_entrypoint_surface: $found_n subcommands ($(echo $found)) all classified; eval entries resolve the classpath"
fi
exit "$fail"
