#!/usr/bin/env bash
# test/e2e/phase15_pr_newline.sh — pr / newline print primitives (D-232).
# `pr` is the readable (quoted) print WITHOUT a trailing newline (the
# no-newline counterpart of prn); `newline` writes a single \n. Both were
# missing. They reuse the shared emitToStdout choke (same path as prn/print).
# (The trailing `nil` in outputs is the cljw -e REPL echo, not from pr.) Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# pr renders a string in READABLE (quoted) form, no trailing newline
assert_eq 'pr-string-quoted' \
  "$("$BIN" -e '(pr "hi")' 2>&1 | head -1)" \
  '"hi"nil'

# print renders the same string UNQUOTED (contrast with pr)
assert_eq 'print-string-unquoted' \
  "$("$BIN" -e '(print "hi")' 2>&1 | head -1)" \
  'hinil'

# pr on a keyword / number is the readable form, no newline
assert_eq 'pr-keyword' \
  "$("$BIN" -e '(pr :a)' 2>&1 | head -1)" \
  ':anil'

# newline emits a line break (single (do …) form, so the echo lands once at
# the end): line 1 = "x", line 2 = "y…"
assert_eq 'newline-line-break' \
  "$("$BIN" -e '(do (print "x") (newline) (print "y"))' 2>&1 | sed -n '1p')" \
  'x'

echo "OK — phase15_pr_newline (4 cases) green"
