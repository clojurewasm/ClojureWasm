#!/usr/bin/env bash
# test/e2e/phase14_format_char_int.sh
#
# D-267 + AD-029: `(format "%c" <int>)`. clj's `%c` accepts Character/Byte/
# Short/Integer but rejects Long, so `(format "%c" (int 65))` -> "A" while
# `(format "%c" 65)` -> IllegalFormatConversionException. cljw collapses
# int/Long into ONE integer type (F-005), so it cannot reproduce clj's
# Integer-accepts / Long-rejects split: cljw rejects `%c` on EVERY integer
# (option (b) in D-267). The common path -- `%c` with an actual char -- is
# clj-parity. This pin locks cljw's intentional divergence: if a future
# change makes `%c` accept integers (option (a)), the int-rejection assert
# fails and forces a conscious decision.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_errors() {
    # The expression must FAIL (non-zero exit) and not print a successful value.
    local name="$1" expr="$2"
    if "$BIN" -e "$expr" >/dev/null 2>&1; then
        fail "$name: expected an error, but it succeeded"
    fi
    echo "PASS $name -> errors (as intended)"
}

# --- Parity: %c with an actual char works in both (the common path) ---
assert_eq 'format_c_char'   "$("$BIN" -e '(format "%c" (char 65))' 2>/dev/null | tail -1)" '"A"'
assert_eq 'format_c_literal' "$("$BIN" -e '(format "%c" \A)' 2>/dev/null | tail -1)" '"A"'

# --- Divergence pins (cljw rejects integers for %c; clj accepts Integer) ---
# clj `(format "%c" (int 65))` -> "A" (Integer accepted); cljw rejects it.
assert_errors 'format_c_int_rejected'  '(format "%c" (int 65))'
# clj `(format "%c" 65)` -> IllegalFormatConversionException (Long); cljw also rejects.
assert_errors 'format_c_long_rejected' '(format "%c" 65)'

echo "OK — phase14_format_char_int (4 cases) green"
