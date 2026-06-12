#!/usr/bin/env bash
# test/e2e/phase14_static_fields.sh
#
# Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
# Java static FIELD reads (bare `Class/FIELD`, no parens). ADR-0061:
# analyzeSymbol resolves the qualified head via resolveJavaSurface, then
# td.lookupStaticField, emitting a `.constant` Node with the value
# (integerLiteralToValue for ints, initFloat for floats).
#
# Long/MAX_VALUE / MIN_VALUE exceed i48 → BigInt (`…N`) where JVM prints a
# bare Long (D-165, value exact) — pinned. Double/MAX_VALUE / MIN_VALUE are
# tested by VALUE (round-trip equality) not print form, because cljw's
# float printer does not use scientific notation (D-166, separate gap).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

check() { # check <expr> <expected> <label>
    local out
    set +e
    out=$("$BIN" -e "$1" 2>&1 | tail -n 1)
    set -e
    [[ "$out" == "$2" ]] || fail "$3: expected '$2', got '$out'"
    echo "PASS $3 -> $2"
}

# --- Integer (fit i48 → clean Long, clj parity) ---
check 'Integer/MAX_VALUE'  '2147483647'   integer_max_value
check 'Integer/MIN_VALUE'  '-2147483648'  integer_min_value

# --- Long (exceed i48 → heap Long, no N; D-165 C7 clj-parity, value exact) ---
check 'Long/MAX_VALUE'     '9223372036854775807'  long_max_value
check 'Long/MIN_VALUE'     '-9223372036854775808' long_min_value

# --- Double — tested by VALUE (round-trip), print form is D-166 ---
check '(= Double/MAX_VALUE (Double/parseDouble "1.7976931348623157E308"))' 'true' double_max_value
check '(= Double/MIN_VALUE (Double/parseDouble "4.9E-324"))'               'true' double_min_value

# --- Fields are first-class values usable in expressions ---
check '(< 0 Integer/MAX_VALUE)' 'true' integer_max_in_expr
check '(pos? Double/MAX_VALUE)'  'true' double_max_pos
# Long fields tested by value-equality, not a sign predicate: neg?/pos?/<
# on a BigInt is a separate pre-existing bug (D-167), out of scope here.
check '(= Long/MIN_VALUE -9223372036854775808)' 'true' long_min_value_eq

# --- A genuinely-unknown ns still raises (regression: the field arm must
#     not swallow real namespace errors) ---
set +e
out=$("$BIN" -e 'totally.unknown.Ns/FIELD' 2>&1)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "unknown_ns_still_errors: expected non-zero exit"
echo "PASS unknown_ns_still_errors -> non-zero exit"

echo "ALL PASS phase14_static_fields"
