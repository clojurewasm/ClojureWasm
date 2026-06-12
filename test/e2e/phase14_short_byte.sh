#!/usr/bin/env bash
# test/e2e/phase14_short_byte.sh
#
# D-295 — java.lang.Short / java.lang.Byte MIN_VALUE / MAX_VALUE static fields
# (ADR-0061 static-field pattern, mirroring Integer/Long). cljw has no short/byte
# primitive type (F-005), so these are plain Long constants. Used by
# clojure.data.generators' short/byte range generators.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
run() { "$BIN" -e "$1" 2>/dev/null; }

assert_eq 'short_max' "$(run 'Short/MAX_VALUE')"  '32767'
assert_eq 'short_min' "$(run 'Short/MIN_VALUE')"  '-32768'
assert_eq 'byte_max'  "$(run 'Byte/MAX_VALUE')"   '127'
assert_eq 'byte_min'  "$(run 'Byte/MIN_VALUE')"   '-128'
# usable in arithmetic (the data.generators usage shape: (inc (long Short/MAX_VALUE)))
assert_eq 'short_arith' "$(run '(inc (long Short/MAX_VALUE))')" '32768'
