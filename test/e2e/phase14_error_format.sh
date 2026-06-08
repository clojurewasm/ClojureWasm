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

# --- Case 8 (ADR-0118 cycle 1): an eval (runtime) error carries a real
#     source location, not `0:0`. Previously the VM op_call passed an empty
#     loc into callFn so deep eval errors surfaced as `<-e>:0:0`. The default
#     (vm) backend must now report the failing call's line. ---
out=$("$BIN" -e '(/ 1 0)' 2>&1 || true)
case "$out" in
    *"Arithmetic error"*"<-e>:1:"*)
        echo "PASS error_eval_loc_backfilled -> eval error has line 1, not 0:0" ;;
    *)
        fail "error_eval_loc_backfilled: eval error should report <-e>:1:<col>, got '$out'" ;;
esac

# --- Case 9 (ADR-0118 cycle 1): a deep eval error in a file points at the
#     failing form's line, not the chunk start. ---
WORK_EL="$(mktemp -d)"
trap 'rm -rf "$WORK_EL"' EXIT
printf '(defn f [x] (/ x 0))\n(defn g [y] (f y))\n(g 10)\n' > "$WORK_EL/nested.clj"
out=$("$BIN" "$WORK_EL/nested.clj" 2>&1 || true)
case "$out" in
    *"Arithmetic error"*"nested.clj:1:"*)
        echo "PASS error_eval_loc_deep -> deep eval error points at the failing line" ;;
    *)
        fail "error_eval_loc_deep: expected nested.clj:1:<col>, got '$out'" ;;
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

echo
echo "Phase 14 row 14.13 (D-066 partial) error format e2e: all green."
