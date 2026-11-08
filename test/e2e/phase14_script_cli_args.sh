#!/usr/bin/env bash
# test/e2e/phase14_script_cli_args.sh: `cljw script.clj a b` matches
# `clojure script.clj a b`: tokens after the script path are script arguments
# bound to *command-line-args* (clojure.main's script contract, D-310), not
# more files to open. Option-looking tokens after the script are args too,
# except a `-cp <dirs>` placed directly after the script path, which stays the
# classpath option (`cljw app.clj -cp lib`, ADR-0135).
# e2e-process-boundary: the subject is the cljw binary's own argv parsing
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

FIX=/tmp/phase14_cli_args_$$.clj
LIBDIR=/tmp/phase14_cli_args_lib_$$
trap 'rm -rf "$FIX" "$LIBDIR"' EXIT
printf '(prn *command-line-args*)\n(prn (count *command-line-args*))\n' > "$FIX"
assert_eq 'no-args'  "$("$BIN" "$FIX" 2>&1 | sed -n 1p)" 'nil'
assert_eq 'two-args' "$("$BIN" "$FIX" extra-arg 2 2>&1 | sed -n 1p)" '("extra-arg" "2")'
assert_eq 'count'    "$("$BIN" "$FIX" a b c 2>&1 | tail -1)" '3'
assert_eq 'flags'    "$("$BIN" "$FIX" -e '"q\"x"' --help 2>&1 | sed -n 1p)" '("-e" "\"q\\\"x\"" "--help")'
# -cp before the script still applies; the arg after it is not a file.
assert_eq 'cp-first' "$("$BIN" -cp . "$FIX" nofile.clj 2>&1 | sed -n 1p)" '("nofile.clj")'

# -cp directly after the script is still the classpath; later tokens are args,
# including a later -cp.
mkdir -p "$LIBDIR/cliargs"
printf '(ns cliargs.lib)\n(def v :from-lib)\n' > "$LIBDIR/cliargs/lib.clj"
printf '(require (quote cliargs.lib))\n(prn cliargs.lib/v *command-line-args*)\n' > "$FIX"
assert_eq 'cp-after'      "$("$BIN" "$FIX" -cp "$LIBDIR" 2>&1 | sed -n 1p)" ':from-lib nil'
assert_eq 'cp-after-args' "$("$BIN" "$FIX" -cp "$LIBDIR" x -cp y 2>&1 | sed -n 1p)" ':from-lib ("x" "-cp" "y")'

# Errors keep exact script line numbers (the setter rides line 1, no newline).
printf '(prn 1)\n(prn 2)\n(undefined-fn-xyz)\n' > "$FIX"
assert_eq 'line-no' "$("$BIN" "$FIX" a 2>&1 | grep -oE '\.clj:[0-9]+' | sed -n 1p)" '.clj:3'
echo "phase14_script_cli_args: OK"
