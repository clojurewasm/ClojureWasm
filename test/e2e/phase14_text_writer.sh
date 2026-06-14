#!/usr/bin/env bash
# test/e2e/phase14_text_writer.sh — ADR-0138 Track C build-step 1: the durable
# cljw-native Writer VALUE foundation (text_io.zig), before the *out*/*err* root
# flip. Exercises the rt/ prims directly: __string-writer / __stdout-writer /
# __writer->str + the write/append/flush/close method_table (string content +
# int-codepoint arm + chainable append). The root flip + with-out-str rewrite
# are build-step 2; the reader value is build-step 3.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# String writer: write (string) + append (chainable) accumulate; __writer->str reads.
assert_eq 'string_write_append' "$("$BIN" - <<'EOF' 2>/dev/null
(let [w (rt/__string-writer)]
  (.write w "hi")
  (.append w "!")
  (prn (rt/__writer->str w)))
EOF
)" '"hi!"'

# write with an int writes that codepoint as a char (Writer.write(int) contract).
assert_eq 'string_write_int_codepoint' "$("$BIN" - <<'EOF' 2>/dev/null
(let [w (rt/__string-writer)]
  (.write w "A")
  (.write w 66)   ; 'B'
  (.write w 67)   ; 'C'
  (prn (rt/__writer->str w)))
EOF
)" '"ABC"'

# append returns the writer (so it threads); flush/close are no-ops on a string writer.
assert_eq 'append_returns_writer' "$("$BIN" - <<'EOF' 2>/dev/null
(let [w (rt/__string-writer)]
  (-> w (.append "a") (.append "b") (.append "c"))
  (.flush w)
  (.close w)
  (prn (rt/__writer->str w)))
EOF
)" '"abc"'

# (class w) is the simple name "Writer" (AD-003 / no-JVM), not a java.io.* hierarchy.
assert_eq 'class_simple_name' "$("$BIN" - <<'EOF' 2>/dev/null
(prn (class (rt/__string-writer)))
EOF
)" 'Writer'

# A stdout writer write-through prints to the process stream immediately.
assert_eq 'stdout_writer_writethrough' "$("$BIN" - <<'EOF' 2>/dev/null
(let [w (rt/__stdout-writer)]
  (.write w "out-")
  (.append w "through")
  (.flush w))
EOF
)" 'out-through'

echo "OK — phase14_text_writer (5 cases) green"
