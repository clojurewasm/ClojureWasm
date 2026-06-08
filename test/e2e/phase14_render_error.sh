#!/usr/bin/env bash
# test/e2e/phase14_render_error.sh
#
# Phase 14 §9.16 row 14.11 D-100(c) — `cljw render-error <path>`
# decodes EDN error events written by `CLJW_ERROR_LOG` (per
# docs/spec/error_format.md) into human-readable text matching the
# in-process renderer's format.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

log_file=$(mktemp -t cljw_renderr.XXXXXX)
trap 'rm -f "$log_file"' EXIT

# --- Case 1: round-trip — emit an error to the log + decode it back ---
CLJW_ERROR_LOG="$log_file" "$BIN" -e '(undefined-symbol)' 2>/dev/null || true
out=$("$BIN" render-error "$log_file" 2>/dev/null)
case "$out" in
    *"Name error"*"Unable to resolve symbol: 'undefined-symbol'"*)
        echo "PASS render_error_roundtrip -> human-readable visible" ;;
    *)
        fail "render_error_roundtrip: expected name_error decoded, got '$out'" ;;
esac

# --- Case 2: multiple events render as multiple blocks ---
> "$log_file"
CLJW_ERROR_LOG="$log_file" "$BIN" -e '(foo)' 2>/dev/null || true
CLJW_ERROR_LOG="$log_file" "$BIN" -e '(bar)' 2>/dev/null || true
out=$("$BIN" render-error "$log_file" 2>/dev/null)
foo_count=$(echo "$out" | grep -c "'foo'" || true)
bar_count=$(echo "$out" | grep -c "'bar'" || true)
[[ "$foo_count" -eq 1 ]] && [[ "$bar_count" -eq 1 ]] || \
    fail "render_error_multiple_events: expected 1×'foo' + 1×'bar', got foo=$foo_count bar=$bar_count"
echo "PASS render_error_multiple_events -> both events decoded"

# --- Case 3: non-cljw lines pass through unchanged ---
> "$log_file"
echo "external log line — not a cljw event" >> "$log_file"
CLJW_ERROR_LOG="$log_file" "$BIN" -e '(baz)' 2>/dev/null || true
out=$("$BIN" render-error "$log_file" 2>/dev/null)
case "$out" in
    *"external log line — not a cljw event"*"'baz'"*)
        echo "PASS render_error_passthrough -> mixed-log pass-through" ;;
    *)
        fail "render_error_passthrough: expected pass-through + event, got '$out'" ;;
esac

# --- Case 4: missing-path argument reports error + exits non-zero ---
exit_code=0
"$BIN" render-error 2>/dev/null >/dev/null || exit_code=$?
[[ "$exit_code" -ne 0 ]] || fail "render_error_missing_arg: expected non-zero exit"
echo "PASS render_error_missing_arg -> non-zero exit"

# --- Case 5: missing-file path reports error + exits non-zero ---
exit_code=0
"$BIN" render-error /tmp/cljw_does_not_exist_$$.log 2>/dev/null >/dev/null || exit_code=$?
[[ "$exit_code" -ne 0 ]] || fail "render_error_missing_file: expected non-zero exit"
echo "PASS render_error_missing_file -> non-zero exit"

echo
echo "Phase 14 row 14.11 D-100(c) cljw render-error e2e: all green."
