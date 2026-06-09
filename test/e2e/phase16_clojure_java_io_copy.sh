#!/usr/bin/env bash
# test/e2e/phase16_clojure_java_io_copy.sh
#
# ADR-0126 Cycle 5 — clojure.java.io/copy over the buffer-backed host_stream.
# Input: Reader/InputStream/File/String(content). Output: Writer/OutputStream/
# File/String(path). Only copy-opened (File/String) streams are closed.

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

TMP="/tmp/cljw_cji_copy"; rm -rf "$TMP"; mkdir -p "$TMP"
printf 'file-source-bytes' > "$TMP/src.txt"

# Multi-form copy round-trips via a fixture file (require + sequential eval).
cat > "$TMP/copy.clj" <<EOF
(require '[clojure.java.io :as io])
;; String CONTENT -> File path
(io/copy "from-string" "$TMP/o_str.txt")
;; File -> File
(io/copy (io/file "$TMP/src.txt") (io/file "$TMP/o_file.txt"))
;; reader -> a passed writer (caller's with-open closes it)
(with-open [w (io/writer "$TMP/o_pass.txt")]
  (io/copy (io/reader "$TMP/src.txt") w))
;; input-stream -> output-stream (binary transport)
(with-open [o (io/output-stream "$TMP/o_bin.txt")]
  (io/copy (io/input-stream "$TMP/src.txt") o))
(println "done")
EOF
"$BIN" "$TMP/copy.clj" >/dev/null 2>&1 || fail "copy fixture run failed"

assert_eq 'str_to_file'    "$(cat "$TMP/o_str.txt")"  'from-string'
assert_eq 'file_to_file'   "$(cat "$TMP/o_file.txt")" 'file-source-bytes'
assert_eq 'reader_to_passed_writer' "$(cat "$TMP/o_pass.txt")" 'file-source-bytes'
assert_eq 'instream_to_outstream'   "$(cat "$TMP/o_bin.txt")"  'file-source-bytes'

# bad args throw (single-form, fully-qualified)
assert_eq 'copy_bad_in'  "$("$BIN" -e '(try (clojure.java.io/copy 1 "/tmp/x") (catch Throwable e :threw))' 2>&1 | tail -n1)" ':threw'
assert_eq 'copy_bad_out' "$("$BIN" -e '(try (clojure.java.io/copy "ok" 2) (catch Throwable e :threw))' 2>&1 | tail -n1)" ':threw'

rm -rf "$TMP"
echo "ALL PASS phase16_clojure_java_io_copy"
