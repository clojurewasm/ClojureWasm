#!/usr/bin/env bash
# test/e2e/phase3_cli.sh
#
# Pin the §9.5 / 3.1 CLI entry points: `cljw -e <expr>`,
# `cljw <file.clj>`, and `cljw -` (stdin) all run the
# Read-Analyse-Eval-Print loop end-to-end.
#
# This locks in the **CLI plumbing** added in 3.1. It deliberately
# does *not* assert on the source-line/caret diagnostic shape —
# tasks 3.2/3.3/3.4 progressively route Reader / Analyzer / Eval
# error sites through `setErrorFmt`, at which point the full
# `<file>:<line>:<col>: <kind> [<phase>]\n  <line>\n  ^\n<msg>`
# rendering kicks in. For now we only verify the catch path runs
# and produces non-empty stderr on a known type error.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
WORK="$(mktemp -d -t cljw_phase3_cli.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building (Debug)"
zig build >/dev/null

if [[ ! -x "$BIN" ]]; then
    echo "✗ binary missing: $BIN" >&2
    exit 1
fi

fail() {
    echo "✗ $1" >&2
    exit 1
}

# --- Case 1: -e <expr> ---
got=$("$BIN" -e '(+ 1 2)' 2>&1) || fail "-e: non-zero exit"
[[ "$got" == "3" ]] || fail "-e: want '3', got '$got'"
echo "    ✓ -e '(+ 1 2)' → 3"

# --- Case 2: <file.clj> ---
fixture="$WORK/script.clj"
printf '(let* [x 10] (+ x 32))\n' > "$fixture"
got=$("$BIN" "$fixture" 2>&1) || fail "file: non-zero exit"
[[ "$got" == "42" ]] || fail "file: want '42', got '$got'"
echo "    ✓ <file.clj> → 42"

# --- Case 3: stdin ('-') ---
got=$("$BIN" - <<'EOF' 2>&1
((fn* [x] (+ x 1)) 41)
EOF
) || fail "stdin: non-zero exit"
[[ "$got" == "42" ]] || fail "stdin: want '42', got '$got'"
echo "    ✓ - (stdin/heredoc) → 42"

# --- Case 4: catch path renders SOMETHING (label + non-empty) ---
err=$("$BIN" -e '(+ 1 :foo)' 2>&1 || true)
[[ -n "$err" ]] || fail "error path: produced empty output"
[[ "$err" == *"<-e>"* ]] || fail "error path: missing source label, got: $err"
echo "    ✓ error path renders with <-e> label"

# --- Case 5: missing file path is reported ---
err=$("$BIN" /nonexistent/path.clj 2>&1 || true)
[[ "$err" == *"Error opening"* ]] || fail "missing file: bad message: $err"
echo "    ✓ missing file is reported"

# --- Case 6: unknown option flagged ---
err=$("$BIN" --not-a-real-flag 2>&1 || true)
[[ "$err" == *"Unknown option"* ]] || fail "unknown flag: bad message: $err"
echo "    ✓ unknown option flagged"

# --- Case 7: heap String round-trips through Read-Eval-Print (3.5) ---
got=$("$BIN" -e '"hello"' 2>&1) || fail "string lit: non-zero exit"
[[ "$got" == '"hello"' ]] || fail "string lit: want '\"hello\"', got '$got'"
echo "    ✓ \"hello\" → \"hello\""

# --- Case 8: quoted string lifts to a heap String ---
got=$("$BIN" -e '(quote "hi")' 2>&1) || fail "quote string: non-zero exit"
[[ "$got" == '"hi"' ]] || fail "quote string: want '\"hi\"', got '$got'"
echo "    ✓ (quote \"hi\") → \"hi\""

# --- Case 9: escape sequences survive Read → printValue round-trip ---
got=$("$BIN" - <<'EOF' 2>&1
"line1\nline2"
EOF
) || fail "escape seq: non-zero exit"
[[ "$got" == '"line1\nline2"' ]] || fail "escape seq: want '\"line1\\nline2\"', got '$got'"
echo "    ✓ \"line1\\nline2\" round-trip"

echo
echo "Phase-3 CLI entry points: all green."
