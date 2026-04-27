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

# --- Case 10: heap List round-trips through quote (3.6) ---
got=$("$BIN" - <<'EOF' 2>&1
(quote (1 2 3))
EOF
) || fail "quote list: non-zero exit"
[[ "$got" == "(1 2 3)" ]] || fail "quote list: want '(1 2 3)', got '$got'"
echo "    ✓ (quote (1 2 3)) → (1 2 3)"

# --- Case 11: mixed-type quoted list ---
got=$("$BIN" - <<'EOF' 2>&1
(quote (1 :a "b"))
EOF
) || fail "mixed list: non-zero exit"
[[ "$got" == '(1 :a "b")' ]] || fail "mixed list: want '(1 :a \"b\")', got '$got'"
echo "    ✓ (quote (1 :a \"b\")) → (1 :a \"b\")"

# --- Case 12: bootstrap macro `let` (3.7) ---
got=$("$BIN" - <<'EOF' 2>&1
(let [x 1] (+ x 2))
EOF
) || fail "let macro: non-zero exit"
[[ "$got" == "3" ]] || fail "let macro: want '3', got '$got'"
echo "    ✓ (let [x 1] (+ x 2)) → 3"

# --- Case 13: bootstrap macro `when` truthy (3.7) ---
got=$("$BIN" - <<'EOF' 2>&1
(when true 42)
EOF
) || fail "when truthy: non-zero exit"
[[ "$got" == "42" ]] || fail "when truthy: want '42', got '$got'"
echo "    ✓ (when true 42) → 42"

# --- Case 14: bootstrap macro `when` falsy (3.7) ---
got=$("$BIN" - <<'EOF' 2>&1
(when false 42)
EOF
) || fail "when falsy: non-zero exit"
[[ "$got" == "nil" ]] || fail "when falsy: want 'nil', got '$got'"
echo "    ✓ (when false 42) → nil"

# --- Case 15: bootstrap macro `->` thread-first (3.7) ---
got=$("$BIN" - <<'EOF' 2>&1
(-> 1 (+ 2) (* 3))
EOF
) || fail "thread-first: non-zero exit"
[[ "$got" == "9" ]] || fail "thread-first: want '9', got '$got'"
echo "    ✓ (-> 1 (+ 2) (* 3)) → 9"

# --- Case 16: `cond` cascade (3.7) ---
got=$("$BIN" - <<'EOF' 2>&1
(cond false 1 false 2 true 3 false 4)
EOF
) || fail "cond: non-zero exit"
[[ "$got" == "3" ]] || fail "cond: want '3', got '$got'"
echo "    ✓ (cond ...) selects the first truthy → 3"

# --- Case 17: `and` short-circuits, `or` returns first truthy (3.7) ---
got=$("$BIN" - <<'EOF' 2>&1
(and 1 2 3)
EOF
) || fail "and: non-zero exit"
[[ "$got" == "3" ]] || fail "and truthy chain: want '3', got '$got'"
echo "    ✓ (and 1 2 3) → 3 (last truthy)"

got=$("$BIN" - <<'EOF' 2>&1
(or false nil 7)
EOF
) || fail "or: non-zero exit"
[[ "$got" == "7" ]] || fail "or first-truthy: want '7', got '$got'"
echo "    ✓ (or false nil 7) → 7"

# --- Case 18: `if-let` truthy / falsy (3.7) ---
got=$("$BIN" - <<'EOF' 2>&1
(if-let [x 7] (+ x 1) 0)
EOF
) || fail "if-let truthy: non-zero exit"
[[ "$got" == "8" ]] || fail "if-let truthy: want '8', got '$got'"
echo "    ✓ (if-let [x 7] (+ x 1) 0) → 8"

got=$("$BIN" - <<'EOF' 2>&1
(if-let [x false] (+ x 1) 99)
EOF
) || fail "if-let falsy: non-zero exit"
[[ "$got" == "99" ]] || fail "if-let falsy: want '99', got '$got'"
echo "    ✓ (if-let [x false] ... 99) → 99"

# --- Case 19: `when-let` (3.7) ---
got=$("$BIN" - <<'EOF' 2>&1
(when-let [x 5] (+ x 10))
EOF
) || fail "when-let truthy: non-zero exit"
[[ "$got" == "15" ]] || fail "when-let truthy: want '15', got '$got'"
echo "    ✓ (when-let [x 5] (+ x 10)) → 15"

# --- Case 20: ex-info construct + ex-message round-trip (3.10) ---
got=$("$BIN" - <<'EOF' 2>&1
(ex-message (ex-info "boom" 42))
EOF
) || fail "ex-info round-trip: non-zero exit"
[[ "$got" == '"boom"' ]] || fail "ex-info round-trip: want '\"boom\"', got '$got'"
echo "    ✓ (ex-message (ex-info \"boom\" 42)) → \"boom\""

# --- Case 21: ex-data extracts the data Value (3.10) ---
got=$("$BIN" - <<'EOF' 2>&1
(ex-data (ex-info "x" 99))
EOF
) || fail "ex-data: non-zero exit"
[[ "$got" == "99" ]] || fail "ex-data: want '99', got '$got'"
echo "    ✓ (ex-data (ex-info \"x\" 99)) → 99"

# --- Case 22: ex-message returns nil for non-ex-info (3.10) ---
got=$("$BIN" - <<'EOF' 2>&1
(ex-message 42)
EOF
) || fail "ex-message non-exinfo: non-zero exit"
[[ "$got" == "nil" ]] || fail "ex-message non-exinfo: want 'nil', got '$got'"
echo "    ✓ (ex-message 42) → nil"

# --- Case 23: ex-info pr-str renders #error{...} (3.10) ---
got=$("$BIN" - <<'EOF' 2>&1
(ex-info "boom" 1)
EOF
) || fail "ex-info pr-str: non-zero exit"
[[ "$got" == '#error{:message "boom" :data 1}' ]] || fail "ex-info pr-str: want '#error{:message \"boom\" :data 1}', got '$got'"
echo "    ✓ (ex-info \"boom\" 1) → #error{...}"

echo
echo "Phase-3 CLI entry points: all green."
