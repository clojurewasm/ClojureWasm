#!/usr/bin/env bash
# test/e2e/phase14_error_format.sh
#
# Phase 14 §9.16 row 14.13 (partial D-066 discharge):
# `CLJW_ERROR_FORMAT` env var switches the cljw error renderer
# between human-readable text (default) and structured EDN suitable
# for `cljw render-error` post-mortem decoding.
#
# `CLJW_ERROR_LOG` (file append) is the sibling polish piece —
# filed as D-066 follow-up; not in this row.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

# --- Case 1: default format is text (carat-pointer style) ---
out=$("$BIN" -e '(undefined-symbol)' 2>&1 || true)
case "$out" in
    *"Unable to resolve symbol"*)
        echo "PASS error_format_text_default -> message visible" ;;
    *)
        fail "error_format_text_default: missing text message; got '$out'" ;;
esac

# --- Case 2: CLJW_ERROR_FORMAT=edn emits structured map on stderr ---
out=$(CLJW_ERROR_FORMAT=edn "$BIN" -e '(undefined-symbol)' 2>&1 1>/dev/null || true)
case "$out" in
    *"{:cljw/error true"*":kind :name_error"*)
        echo "PASS error_format_edn_emits_structured_map -> EDN visible" ;;
    *)
        fail "error_format_edn_emits_structured_map: missing EDN structure; got '$out'" ;;
esac

# --- Case 3: CLJW_ERROR_FORMAT=edn carries :phase and :message ---
out=$(CLJW_ERROR_FORMAT=edn "$BIN" -e '(undefined-symbol)' 2>&1 1>/dev/null || true)
case "$out" in
    *":phase :analysis"*":message \"Unable to resolve symbol: 'undefined-symbol'\""*)
        echo "PASS error_format_edn_carries_phase_and_message -> fields visible" ;;
    *)
        fail "error_format_edn_carries_phase_and_message: expected :phase + :message in '$out'" ;;
esac

# --- Case 4: unknown CLJW_ERROR_FORMAT value falls back to text ---
out=$(CLJW_ERROR_FORMAT=xml "$BIN" -e '(undefined-symbol)' 2>&1 1>/dev/null || true)
case "$out" in
    *"{:cljw/error"*)
        fail "error_format_unknown_fallback: unexpected EDN output for CLJW_ERROR_FORMAT=xml: '$out'" ;;
    *"Unable to resolve symbol"*)
        echo "PASS error_format_unknown_fallback -> text fallback for typo'd value" ;;
    *)
        fail "error_format_unknown_fallback: expected text output for CLJW_ERROR_FORMAT=xml, got '$out'" ;;
esac

# --- Case 5: EDN output is single-line (parseable by line-based tools) ---
out=$(CLJW_ERROR_FORMAT=edn "$BIN" -e '(undefined-symbol)' 2>&1 1>/dev/null || true)
line_count=$(echo "$out" | grep -c '^{:cljw/error' || true)
[[ "$line_count" -eq 1 ]] || fail "error_format_edn_single_line: expected 1 EDN line, got $line_count"
echo "PASS error_format_edn_single_line -> one EDN map per error"

# --- Case 6: CLJW_ERROR_LOG appends EDN event to the file path ---
log_file=$(mktemp -t cljw_errlog.XXXXXX)
trap 'rm -f "$log_file"' EXIT
CLJW_ERROR_LOG="$log_file" "$BIN" -e '(undefined-symbol)' 2>/dev/null || true
[[ -s "$log_file" ]] || fail "error_log_writes_file: log file is empty"
contents=$(cat "$log_file")
case "$contents" in
    *"{:cljw/error true"*":kind :name_error"*)
        echo "PASS error_log_writes_edn_event -> file contains EDN" ;;
    *)
        fail "error_log_writes_edn_event: expected EDN in '$contents'" ;;
esac

# --- Case 7: CLJW_ERROR_LOG appends (does not truncate) on repeat ---
CLJW_ERROR_LOG="$log_file" "$BIN" -e '(another-undefined)' 2>/dev/null || true
line_count=$(grep -c '^{:cljw/error' "$log_file" || true)
[[ "$line_count" -eq 2 ]] || fail "error_log_appends_does_not_truncate: expected 2 EDN lines, got $line_count"
echo "PASS error_log_appends_on_repeat -> 2 events in file"

# --- Case 8 (ADR-0118 cycle 2.5): an eval (runtime) error carries an
#     ARG-PRECISE source location — the caret lands on the culprit operand,
#     not the enclosing call form. `(/ 1 0)` divides by the divisor at index
#     1, so the column is the `0` (col 5: `(`=0 `/`=1 ` `=2 `1`=3 ` `=4 `0`=5),
#     NOT the opening `(` at col 0. ---
out=$("$BIN" -e '(/ 1 0)' 2>&1 || true)
case "$out" in
    *"Arithmetic error"*"<-e>:1:5"*)
        echo "PASS error_eval_loc_arg_precise -> caret on the divisor (col 5)" ;;
    *)
        fail "error_eval_loc_arg_precise: eval error should report <-e>:1:5 (the divisor), got '$out'" ;;
esac

# --- Case 9 (ADR-0118 cycle 2.5): a deep eval error in a file points at the
#     culprit operand's column. `(/ x 0)` on line 1 has the divisor `0` at
#     col 17 (`(defn f [x] (/ x 0))` — the `0` inside the division). ---
WORK_EL="$(mktemp -d)"
trap 'rm -rf "$WORK_EL"' EXIT
printf '(defn f [x] (/ x 0))\n(defn g [y] (f y))\n(g 10)\n' > "$WORK_EL/nested.clj"
out=$("$BIN" "$WORK_EL/nested.clj" 2>&1 || true)
case "$out" in
    *"Arithmetic error"*"nested.clj:1:17"*)
        echo "PASS error_eval_loc_deep -> deep eval error points at the divisor column" ;;
    *)
        fail "error_eval_loc_deep: expected nested.clj:1:18 (the divisor), got '$out'" ;;
esac

# --- Case 10 (ADR-0118 E.1): EDN :file is the source label, not "unknown".
#     The analyzer/eval set line:col but not file; the EDN emitter must apply
#     the same ctx.file fallback the text renderer uses. ---
out=$(CLJW_ERROR_FORMAT=edn "$BIN" -e '(/ 1 0)' 2>&1 1>/dev/null || true)
case "$out" in
    *':file "<-e>"'*)
        echo "PASS error_edn_file_label -> EDN :file is the source label" ;;
    *)
        fail "error_edn_file_label: EDN :file should be \"<-e>\", not unknown; got '$out'" ;;
esac

# --- Case 11 (ADR-0119 Stage 2): an uncaught error renders a `Trace:` of the
#     runtime call stack, named fns innermost-first (tf called by tg). Functions
#     carry their name on the value (Stage 1), so frames show `user/<fn>`. ---
WORK_TR="$(mktemp -d)"
trap 'rm -rf "$WORK_EL" "$WORK_TR"' EXIT
printf '(defn tf [x] (/ x 0))\n(defn tg [y] (tf y))\n(tg 3)\n' > "$WORK_TR/trace.clj"
out=$("$BIN" "$WORK_TR/trace.clj" 2>&1 || true)
case "$out" in
    *"Trace:"*"user/tf"*"user/tg"*)
        echo "PASS error_trace_named_frames -> Trace: shows user/tf then user/tg" ;;
    *)
        fail "error_trace_named_frames: expected a Trace: with user/tf + user/tg, got '$out'" ;;
esac

# --- Case 12 (ADR-0119 Stage 2): EDN :trace mirrors the text Trace: in lockstep
#     (ADR-0055) — a `:trace [{:fn "tf" ...} ...]` vector. ---
out=$(CLJW_ERROR_FORMAT=edn "$BIN" "$WORK_TR/trace.clj" 2>&1 1>/dev/null || true)
case "$out" in
    *':trace ['*':fn "tf"'*':fn "tg"'*)
        echo "PASS error_edn_trace -> EDN :trace mirrors the text trace" ;;
    *)
        fail "error_edn_trace: expected EDN :trace with :fn \"tf\"/\"tg\", got '$out'" ;;
esac

# --- Case 13 (ADR-0119 / D-332): the trace-visibility DISCIPLINE. cw stdlib
#     (`clojure.*` / `cljw.*`) and host (builtin) frames are elided uniformly;
#     only USER frames show. `(map userfn coll)` where userfn errors → the trace
#     shows the user fn, NOT `clojure.core/map` and NOT a nameless internal
#     `fn` frame. (`map` is a .clj stdlib fn over the `-map-eager` builtin.) ---
out=$(printf '(prn (map (fn* [x] (/ x 0)) [1 2]))\n' | "$BIN" - 2>&1 || true)
trace=$(printf '%s' "$out" | awk '/Trace:/{f=1} f')
if [ -z "$trace" ]; then
    fail "error_trace_discipline: expected a Trace:, got '$out'"
elif printf '%s' "$trace" | grep -q 'clojure\.'; then
    fail "error_trace_discipline: a clojure.* stdlib frame leaked into the trace: '$trace'"
elif printf '%s' "$trace" | grep -qE '^  fn '; then
    fail "error_trace_discipline: a nameless internal 'fn' frame leaked into the trace: '$trace'"
elif printf '%s' "$trace" | grep -q 'user/'; then
    echo "PASS error_trace_discipline -> user-only trace (stdlib + host frames elided)"
else
    fail "error_trace_discipline: expected a user/ frame in the trace, got '$trace'"
fi

# --- Case 14 (ADR-0120 Stage A): a synthesized internal exception carries its
#     ORIGIN location across a catch -> re-throw, so it renders WHERE it came
#     from (not "unknown"). Before ADR-0120 buildThrownInfo dropped the location
#     for any thrown ex_info; now the widened ExInfo round-trips it (the founda-
#     tion for cross-thread future/agent error fidelity, ADR-0120 Stage B). ---
out=$(printf '(throw (try (/ 1 0) (catch java.lang.Throwable e e)))\n' | "$BIN" - 2>&1 || true)
case "$out" in
    *"<stdin>:1:"*"Divide by zero"*)
        echo "PASS error_thrown_keeps_location -> re-thrown synth exception shows its origin loc" ;;
    *)
        fail "error_thrown_keeps_location: expected a <stdin>:1:<col> location + message, got '$out'" ;;
esac

# --- Case 15 (ADR-0120 Stage B): a future thunk error crosses the REAL OS
#     thread boundary (future.zig:103) faithfully — `@(future (/ 1 0))` shows the
#     real "Divide by zero" + location, NOT a generic future_thunk_failed. The
#     worker marshals its threadlocal error into a GC-heap exception Value that
#     survives the thread; deref re-raises it. ---
out=$(printf '@(future (/ 1 0))\n' | "$BIN" - 2>&1 || true)
case "$out" in
    *"future_thunk_failed"*)
        fail "error_future_fidelity: future error still generic future_thunk_failed: '$out'" ;;
    *"<stdin>:1:"*"Divide by zero"*)
        echo "PASS error_future_fidelity -> future error crosses with real message + location" ;;
    *)
        fail "error_future_fidelity: expected Divide by zero + location, got '$out'" ;;
esac

# --- Case 16 (ADR-0120 Stage B): the KIND-DERIVED class crosses too, so a
#     future's arithmetic error is catchable as ArithmeticException — fixing the
#     old hardcoded-ExceptionInfo marshal. Proves the class (not just the
#     message) is faithful across the boundary. ---
out=$(printf '(prn (try @(future (/ 1 0)) (catch java.lang.ArithmeticException e (.getMessage e))))\n' | "$BIN" - 2>&1 || true)
case "$out" in
    *'"Divide by zero"'*)
        echo "PASS error_future_catchable_class -> future error catchable by its real class" ;;
    *)
        fail "error_future_catchable_class: expected to catch ArithmeticException, got '$out'" ;;
esac

# --- Case 17 (ADR-0120 / D-329): per-thread error ISOLATION — two concurrent
#     futures each raising a DIFFERENT error, caught independently, each surface
#     their OWN error (the call_stack/last_error/trace_snapshot are all
#     threadlocal, so worker threads don't cross-contaminate). ---
out=$(printf '(prn [(try @(future (/ 1 0)) (catch java.lang.Throwable e (.getMessage e))) (try @(future (throw (ex-info "BBB" {}))) (catch java.lang.Throwable e (.getMessage e)))])\n' | "$BIN" - 2>&1 || true)
case "$out" in
    *'["Divide by zero" "BBB"]'*)
        echo "PASS error_future_isolation -> concurrent futures keep their own errors" ;;
    *)
        fail "error_future_isolation: expected [\"Divide by zero\" \"BBB\"], got '$out'" ;;
esac

# --- Case 18 (ADR-0119 / D-331 + D-334): a stack trace spans MULTIPLE MODULES
#     across a require chain — each frame carries its DEFINING ns AND its own
#     module FILE (execution-point lines, D-334). myx.mid/run calls
#     myx.leaf/boom which errors; the leaf frame shows leaf.clj, the mid frame
#     shows mid.clj — ns and file agree per frame across the module boundary. ---
WORK_MM="$(mktemp -d)"
trap 'rm -rf "$WORK_EL" "$WORK_TR" "$WORK_MM"' EXIT
mkdir -p "$WORK_MM/src/myx"
printf '{:paths ["src"]}\n' > "$WORK_MM/deps.edn"
printf '(ns myx.leaf)\n(defn boom [x] (/ x 0))\n' > "$WORK_MM/src/myx/leaf.clj"
printf '(ns myx.mid (:require [myx.leaf]))\n(defn run [] (myx.leaf/boom 3))\n' > "$WORK_MM/src/myx/mid.clj"
# Absolute BIN: deps.edn resolution needs cwd = the project, so we `cd` away
# from the repo — a relative `$BIN` would not resolve there.
ABS_BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
out=$(cd "$WORK_MM" && "$ABS_BIN" -e "(require 'myx.mid) (myx.mid/run)" 2>&1 || true)
trace=$(printf '%s' "$out" | awk '/Trace:/{f=1} f')
case "$trace" in
    *"myx.leaf/boom"*"leaf.clj"*"myx.mid/run"*"mid.clj"*)
        echo "PASS error_trace_multi_module -> trace spans modules; per-frame ns + file agree" ;;
    *)
        fail "error_trace_multi_module: expected leaf frame@leaf.clj + mid frame@mid.clj, got '$trace'" ;;
esac

# --- Case 19 (ADR-0120 §1 / D-336): the worker's TRACE crosses the thread
#     boundary too — `@(future (boom))` renders a Trace: naming the user frame
#     `user/boom`, not just the message+location. The trace is deep-copied onto
#     the marshalled ExInfo (the worker's threadlocal trace_snapshot dies with
#     the thread). ---
out=$(printf '(defn boom [] (/ 1 0))\n@(future (boom))\n' | "$BIN" - 2>&1 || true)
trace=$(printf '%s' "$out" | awk '/Trace:/{f=1} f')
case "$trace" in
    *"Trace:"*"user/boom"*)
        echo "PASS error_future_trace_crosses -> future error carries its Trace: across the thread boundary" ;;
    *)
        fail "error_future_trace_crosses: expected a Trace: naming user/boom, got '$out'" ;;
esac

# --- Case 20 (ADR-0120 §1 / D-336): an in-thread thrown synth exception carries
#     its trace too — `(throw (try (boom) (catch Throwable e e)))` re-throws the
#     caught ex_info and renders user/boom in the Trace:, closing the latent
#     in-thread gap (buildThrownInfo used to drop the trace for any thrown
#     ex_info). ---
out=$(printf '(defn boom [] (/ 1 0))\n(throw (try (boom) (catch java.lang.Throwable e e)))\n' | "$BIN" - 2>&1 || true)
trace=$(printf '%s' "$out" | awk '/Trace:/{f=1} f')
case "$trace" in
    *"Trace:"*"user/boom"*)
        echo "PASS error_thrown_trace_inthread -> a re-thrown synth exception carries its Trace:" ;;
    *)
        fail "error_thrown_trace_inthread: expected a Trace: naming user/boom, got '$out'" ;;
esac

echo
echo "Phase 14 row 14.13 (D-066 partial) error format e2e: all green."
