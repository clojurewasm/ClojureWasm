#!/usr/bin/env bash
# test/e2e/phase16_stdin_read_line.sh — `(read-line)` on process stdin.
#
# The 2026-07-06 user-filed bug: `*in*`'s root was nil (no process-stdin
# reader), so `(read-line)` returned nil on piped/redirected/interactive
# stdin while clj/bb read the lines. The root is now `(cljw.internal/__stdin-reader)`
# — a demand-filled blocking reader over process stdin (clj System.in
# parity). Layer 2 (e2e CLI) per ADR-0021; non-TTY stdin is exactly what
# this harness provides, so the regression is CI-visible.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# Piped stdin: two lines then EOF (clj: ["hello" "world" nil]).
assert_eq 'pipe_lines' \
  "$(printf 'hello\nworld\n' | "$BIN" -e '(pr-str [(read-line) (read-line) (read-line)])' | tail -1)" \
  '"[\"hello\" \"world\" nil]"'

# File redirect behaves the same (not pipe-specific).
tmp_in="$(mktemp)"; printf 'redirected\n' > "$tmp_in"
assert_eq 'redirect_line' \
  "$("$BIN" -e '(read-line)' < "$tmp_in" | tail -1)" \
  '"redirected"'
rm -f "$tmp_in"

# A final line WITHOUT a trailing newline still reads (EOF-terminated line).
assert_eq 'no_trailing_newline' \
  "$(printf 'lastline' | "$BIN" -e '(pr-str [(read-line) (read-line)])' | tail -1)" \
  '"[\"lastline\" nil]"'

# CRLF terminators are stripped (the reader's \r\n handling on stdin).
assert_eq 'crlf' \
  "$(printf 'crlf\r\n' | "$BIN" -e '(read-line)' | tail -1)" \
  '"crlf"'

# with-in-str still shadows the stdin root (string reader wins inside).
assert_eq 'with_in_str_shadows' \
  "$(printf 'outer\n' | "$BIN" -e '(pr-str [(with-in-str "inner\n" (read-line)) (read-line)])' | tail -1)" \
  '"[\"inner\" \"outer\"]"'

# .read on stdin: codepoints stream through (multibyte-safe demand fill).
assert_eq 'read_codepoint' \
  "$(printf 'あZ' | "$BIN" -e '(pr-str [(.read *in*) (.read *in*) (.read *in*)])' | tail -1)" \
  '"[12354 90 -1]"'

# slurp on process stdin drains the whole remainder to EOF (-e pr-prints it).
assert_eq 'slurp_stdin' \
  "$(printf 'piped-stdin-content' | "$BIN" -e '(slurp *in*)' | tail -1)" \
  '"piped-stdin-content"'

# slurp drains only the UNREAD remainder after a read-line consumed a line.
assert_eq 'slurp_stdin_after_read_line' \
  "$(printf 'first\nrest-of-stream' | "$BIN" -e '(do (read-line) (slurp *in*))' | tail -1)" \
  '"rest-of-stream"'

# System/in is the OTHER stdin object (a host_stream, not the *in* reader):
# slurp drains it to EOF too, not to whatever a prior .read happened to buffer.
assert_eq 'slurp_system_in' \
  "$(printf 'sysin-data' | "$BIN" -e '(slurp System/in)' | tail -1)" \
  '"sysin-data"'

# …and after a .read consumed one byte, only the remainder drains.
assert_eq 'slurp_system_in_after_read' \
  "$(printf 'Xrest-of-stream' | "$BIN" -e '(do (.read System/in) (slurp System/in))' | tail -1)" \
  '"rest-of-stream"'

echo "ALL phase16_stdin_read_line PASS"
