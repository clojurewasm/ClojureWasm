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
zig build >/dev/null

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

echo
echo "Phase 14 row 14.13 (D-066 partial) error format e2e: all green."
