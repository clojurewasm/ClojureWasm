#!/usr/bin/env bash
# test/e2e/phase14_repl.sh
#
# Phase 14 §9.16 row 14.9 — `cljw repl` minimal REPL (F144
# re-introduction, line-buffered) per ADR-0048 state machine chart.
# Piped-stdin tests cover the read-eval-print loop without a TTY.
# Arrow-key history + cursor editing are filed as follow-up D-116
# (pre-v0.1.0 polish if scope allows; otherwise post-v0.1.0).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

## The REPL prints `<ns>=> ` (no trailing newline) then the result +
## newline on the same line so every value lands right after a prompt.
## Tests strip the `<ns>=> ` prefix to recover the value tokens.
strip_prompts() { sed -E 's/^([a-zA-Z][a-zA-Z0-9._-]*=> )+//'; }

# --- Case 1: single-form line yields one printed value ---
got=$(printf '(+ 1 2)\n' | "$BIN" repl 2>/dev/null | strip_prompts | grep -vE '^(ClojureWasm|$)' | head -n 1)
[[ "$got" == '3' ]] || fail "repl_single_form_arith: expected '3', got '$got'"
echo "PASS repl_single_form_arith -> 3"

# --- Case 2: def + reference produce two outputs ---
out=$(printf '(def x 42)\nx\n' | "$BIN" repl 2>/dev/null | strip_prompts | grep -vE '^(ClojureWasm|$)' | head -n 3)
case "$out" in
    *"42"*)
        echo "PASS repl_def_then_ref -> 42 visible" ;;
    *)
        fail "repl_def_then_ref: expected '42' in output, got '$out'" ;;
esac

# --- Case 3: empty input + EOF exits cleanly ---
exit_code=0
printf '' | "$BIN" repl >/dev/null 2>&1 || exit_code=$?
[[ "$exit_code" -eq 0 ]] || fail "repl_eof_clean_exit: expected exit 0, got $exit_code"
echo "PASS repl_eof_clean_exit"

# --- Case 4: parse error on one line does not abort the REPL ---
out=$(printf '(+ 1\n(* 2 3)\n' | "$BIN" repl 2>&1 | strip_prompts | grep -vE '^(ClojureWasm|$)' | head -n 8)
case "$out" in
    *"6"*)
        echo "PASS repl_error_recovery -> 6 visible after parse-error" ;;
    *)
        fail "repl_error_recovery: expected '6' (from line 2) in output after parse-error, got '$out'" ;;
esac

# --- Case 5: prompt shows the current namespace ---
out=$(printf 'nil\n' | "$BIN" repl 2>&1 | head -n 3)
case "$out" in
    *"user=>"*|*"=> "*)
        echo "PASS repl_prompt_visible -> prompt present" ;;
    *)
        fail "repl_prompt_visible: expected 'user=>' or '=>' in prompt, got '$out'" ;;
esac

echo
echo "Phase 14 row 14.9 REPL minimal e2e: all green."
