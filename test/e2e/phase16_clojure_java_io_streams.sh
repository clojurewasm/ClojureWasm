#!/usr/bin/env bash
# test/e2e/phase16_clojure_java_io_streams.sh
#
# ADR-0126 Cycle 4 — clojure.java.io reader/writer/input-stream/output-stream
# coercion fns + clojure.core/line-seq over the buffer-backed host_stream.

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

TMP="/tmp/cljw_cji_streams"; rm -rf "$TMP"; mkdir -p "$TMP"
printf 'alpha\nbeta\ngamma\n' > "$TMP/lines.txt"

# --- coercion fns return the right family (fully-qualified; eager ns) ---
assert_eq 'reader_class'  "$(run "(class (clojure.java.io/reader \"$TMP/lines.txt\"))")" 'java.io.Reader'
assert_eq 'writer_inst'   "$(run "(instance? java.io.Writer (clojure.java.io/writer \"$TMP/w.txt\"))")" 'true'
assert_eq 'instream_inst' "$(run "(instance? java.io.InputStream (clojure.java.io/input-stream \"$TMP/lines.txt\"))")" 'true'
assert_eq 'outstream_inst' "$(run "(instance? java.io.OutputStream (clojure.java.io/output-stream \"$TMP/o.dat\"))")" 'true'
assert_eq 'reader_idem'   "$(run "(let [r (clojure.java.io/reader \"$TMP/lines.txt\")] (identical? r (clojure.java.io/reader r)))")" 'true'
assert_eq 'reader_of_file' "$(run "(class (clojure.java.io/reader (clojure.java.io/file \"$TMP/lines.txt\")))")" 'java.io.Reader'
assert_eq 'reader_bad'    "$(run '(try (clojure.java.io/reader 42) (catch Throwable e :threw))')" ':threw'

# --- line-seq + with-open round-trips, via fixture files (sequential eval) ---
cat > "$TMP/lineseq.clj" <<EOF
(require '[clojure.java.io :as io])
(println (vec (line-seq (io/reader "$TMP/lines.txt"))))
EOF
assert_eq 'line_seq' "$("$BIN" "$TMP/lineseq.clj" 2>&1 | tail -n 1)" '[alpha beta gamma]'

cat > "$TMP/withopen.clj" <<EOF
(require '[clojure.java.io :as io])
(with-open [w (io/writer "$TMP/out.txt")] (.write w "wrote ") (.write w "it"))
(print (slurp "$TMP/out.txt"))
EOF
assert_eq 'with_open_writer' "$("$BIN" "$TMP/withopen.clj" 2>&1 | tail -n 1)" 'wrote it'

# line-seq counts blank lines (significant)
printf 'a\n\nb\n' > "$TMP/blank.txt"
cat > "$TMP/blankseq.clj" <<EOF
(require '[clojure.java.io :as io])
(println (count (line-seq (io/reader "$TMP/blank.txt"))))
EOF
assert_eq 'line_seq_blank' "$("$BIN" "$TMP/blankseq.clj" 2>&1 | tail -n 1)" '3'

rm -rf "$TMP"
echo "ALL PASS phase16_clojure_java_io_streams"
