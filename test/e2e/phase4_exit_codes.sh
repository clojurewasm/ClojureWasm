#!/usr/bin/env bash
# test/e2e/phase4_exit_codes.sh
#
# ROADMAP §9.6 / 4.26.f — verify per-Kind process exit codes per
# ADR-0019. The user-facing catalog error path must return 1; the
# `internal_error` Kind path must return 70. Unit test in main.zig
# covers the kindToExitCode table; this script exercises the live
# binary across the two user-reachable Kinds.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"

fail() {
    echo "✗ $1" >&2
    exit 1
}

assert_exit() {
    local expected="$1"
    local label="$2"
    shift 2
    local got_stdout got_status
    got_stdout=$("$BIN" "$@" 2>/dev/null) && got_status=0 || got_status=$?
    [[ "$got_status" == "$expected" ]] || \
        fail "$label: want exit $expected, got $got_status (stdout: $got_stdout)"
    echo "    ✓ $label → exit $expected"
}

# Exit-code mapping (kindToExitCode, error_render.zig) is backend-agnostic,
# so test on the production DEFAULT backend (vm — ADR-0070) via bare
# `zig build`. This also leaves the default binary in place for subsequent
# run_all.sh steps (no separate restore needed).
echo "==> Building (default backend)"
zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
[[ -x "$BIN" ]] || fail "binary missing"

# (+ 1 :foo) — type_error during eval. Kind=.type_error → exit 1.
assert_exit 1 "type_error: (+ 1 :foo)" -e '(+ 1 :foo)'

# (throw (ex-info "boom" {})) — user throw. error.ThrownValue with
# no setErrorFmt Info populated; the catch falls back to exit 1.
assert_exit 1 "user-throw: (throw (ex-info ...))" -e '(throw (ex-info "boom" {}))'

# Success path — should be exit 0.
assert_exit 0 "success: (+ 1 2)" -e '(+ 1 2)'

# Syntax error during parse. Kind=.syntax_error → exit 1.
assert_exit 1 "syntax_error: ((unbalanced" -e '((unbalanced'

# Unknown CLI option → exit 1 (pre-eval CLI failure path).
assert_exit 1 "cli: --unknown-flag" --unknown-flag
