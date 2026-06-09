#!/usr/bin/env bash
# test/e2e/phase16_host_stream.sh
#
# ADR-0126 Cycle 3 — generic buffer-backed host_stream (4 family descriptors +
# rt/__open-*/__string-reader/__stream-slurp/__stream-copy primitives + read/
# readLine/write/flush/close methods). The clojure.java.io reader/writer/copy
# fns that wrap these land in Cycle 4-5; this exercises the Zig surface directly.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

run() { "$BIN" -e "$1" 2>&1 | tail -n 1; }
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

TMP="/tmp/cljw_host_stream_test"; rm -rf "$TMP"; mkdir -p "$TMP"

# --- reader: readLine / read / slurp over a string source ---
assert_eq 'readLine_seq' "$(run '(let [r (rt/__string-reader "a\nbb\nccc")] [(.readLine r) (.readLine r) (.readLine r) (.readLine r)])')" '["a" "bb" "ccc" nil]'
assert_eq 'read_byte'    "$(run '(let [r (rt/__string-reader "AB")] [(.read r) (.read r) (.read r)])')" '[65 66 -1]'
assert_eq 'slurp_string' "$(run '(rt/__stream-slurp (rt/__string-reader "hello world"))')" '"hello world"'

# --- reader: blank-line significance (line-seq must not collapse) ---
assert_eq 'blank_lines'  "$(run '(let [r (rt/__string-reader "a\n\nb")] [(.readLine r) (.readLine r) (.readLine r)])')" '["a" "" "b"]'

# --- class / instance? (family; leaf-name recognition is a later cycle) ---
assert_eq 'class_reader'  "$(run '(class (rt/__string-reader "x"))')" 'java.io.Reader'
assert_eq 'inst_reader'   "$(run '(instance? java.io.Reader (rt/__string-reader "x"))')" 'true'
assert_eq 'inst_reader_neg' "$(run '(instance? java.io.Reader 5)')" 'false'
assert_eq 'inst_writer'   "$(run "(instance? java.io.Writer (rt/__open-writer \"$TMP/w.txt\"))")" 'true'
assert_eq 'inst_outstream' "$(run "(instance? java.io.OutputStream (rt/__open-output-stream \"$TMP/o.dat\"))")" 'true'

# --- writer round-trip (write accumulates; close flushes to disk) ---
run "(let [w (rt/__open-writer \"$TMP/out.txt\")] (.write w \"hello \") (.write w \"world\") (.close w))" >/dev/null
assert_eq 'writer_flush' "$(cat "$TMP/out.txt")" 'hello world'

# --- open-reader reads the file back ---
assert_eq 'reader_file'  "$(run "(rt/__stream-slurp (rt/__open-reader \"$TMP/out.txt\"))")" '"hello world"'

# --- stream-copy reader -> writer (binary transport over []u8) ---
run "(let [in (rt/__string-reader \"copied!\") out (rt/__open-writer \"$TMP/copy.txt\")] (rt/__stream-copy in out) (.close out))" >/dev/null
assert_eq 'stream_copy'  "$(cat "$TMP/copy.txt")" 'copied!'

# --- CRLF: readLine strips \r\n ---
printf 'x\r\ny\r\n' > "$TMP/crlf.txt"
assert_eq 'crlf'         "$(run "(let [r (rt/__open-reader \"$TMP/crlf.txt\")] [(.readLine r) (.readLine r) (.readLine r)])")" '["x" "y" nil]'

# --- FS-jail: open under a jail root rejects traversal (env scoped to the cmd) ---
assert_eq 'jail_escape'  "$(CLJW_FS_ROOT="$TMP" "$BIN" -e '(try (rt/__open-reader "../../../etc/passwd") (catch Throwable e :blocked))' 2>&1 | tail -n 1)" ':blocked'

rm -rf "$TMP"
echo "ALL PASS phase16_host_stream"
