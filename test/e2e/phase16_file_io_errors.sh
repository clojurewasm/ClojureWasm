#!/usr/bin/env bash
# test/e2e/phase16_file_io_errors.sh — slurp/spit raise a CATCHABLE exception
# (io_error Kind → java.io.IOException) instead of an uncatchable raw Zig error,
# so a real app can `(try (slurp f) (catch Throwable _ default))`. Demo-driven
# (the edge bookshelf needs file I/O with error handling); ADR-0098 follow-on.

set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# slurp of a missing file is catchable as Throwable.
got=$("$BIN" -e '(try (slurp "/tmp/cljw_no_such_file_zzz.edn") :read (catch Throwable _ :caught))' 2>/dev/null)
assert_eq 'slurp_missing_catchable' "$got" ':caught'

# ...and as java.io.IOException specifically (the io_error Kind class).
got=$("$BIN" -e '(try (slurp "/tmp/cljw_no_such_file_zzz.edn") (catch java.io.IOException _ :ioe))' 2>/dev/null)
assert_eq 'slurp_missing_ioexception' "$got" ':ioe'

# spit into a non-existent directory is catchable.
got=$("$BIN" -e '(try (spit "/cljw_no_such_dir_zzz/x" "y") :wrote (catch Throwable _ :caught))' 2>/dev/null)
assert_eq 'spit_baddir_catchable' "$got" ':caught'

# a successful round-trip still works (no regression).
TMP="/tmp/cljw_io_ok_$$.txt"
got=$("$BIN" -e "(do (spit \"$TMP\" \"hello\") (slurp \"$TMP\"))" 2>/dev/null)
rm -f "$TMP"
assert_eq 'slurp_spit_roundtrip' "$got" '"hello"'

echo "OK — phase16_file_io_errors (4 cases) green"
