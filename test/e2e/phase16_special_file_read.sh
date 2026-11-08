#!/usr/bin/env bash
# test/e2e/phase16_special_file_read.sh: a file that stats as size 0 but yields
# bytes (procfs, sysfs, a FIFO) reads to EOF through slurp, io/reader +
# line-seq, and io/file ([CLJW-PROCFS-READ]). Before the fix every one of these
# returned empty: the positional file reader trusted the stat size as a stop.
#
# procfs only exists on Linux, so this is a no-op elsewhere; the unit test in
# src/runtime/file_io.zig covers the shape on every host with a size-0 double.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ ! -r /proc/version ]; then
  echo "phase16_special_file_read: no /proc on this host, skipped"
  exit 0
fi

if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build failed"
fi

out="$("$BIN" - <<'EOF' 2>&1
(println "slurp-loadavg:" (pos? (count (slurp "/proc/loadavg"))))
(println "slurp-version:" (pos? (count (slurp "/proc/version"))))
(println "reader-lines:" (pos? (count (with-open [r (clojure.java.io/reader "/proc/loadavg")] (doall (line-seq r))))))
(println "io-file:" (pos? (count (slurp (clojure.java.io/file "/proc/version")))))
(println "DONE")
EOF
)" || fail "probe exited non-zero:
$out"

grep -q "slurp-loadavg: true" <<<"$out" || fail "slurp on /proc/loadavg came back empty:
$out"
grep -q "slurp-version: true" <<<"$out" || fail "slurp on /proc/version came back empty:
$out"
grep -q "reader-lines: true" <<<"$out" || fail "io/reader + line-seq on /proc/loadavg saw no lines:
$out"
grep -q "io-file: true" <<<"$out" || fail "slurp on (io/file \"/proc/version\") came back empty:
$out"
grep -q "^DONE$" <<<"$out" || fail "probe did not run to completion:
$out"

echo "Phase 16 / special-file read (size-0 stat, bytes to EOF): all green."
