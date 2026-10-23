#!/usr/bin/env bash
# test/e2e/phase15_var_source_meta.sh — D-563(b), the two halves that need a
# process: (1) DEF META RIDES THE WIRE — an AOT artifact built by `cljw build`
# keeps :doc/:line when it runs as its own executable, and (2) a script run as
# `cljw <file>` labels its Vars with that file's real path and line. The
# in-process meta channel (:line/:column/:file, user meta merge, compiler
# :line wins, computed def-meta, load-file paths) lives in
# test/clj/suites/concurrency_host_test.clj (p15-var-source-meta), and the
# clojure.test (file:line) suffix in test/clj/suites/test_reporters_test.clj.
# e2e-process-boundary: builds an AOT executable with `cljw build` and runs it, plus a `cljw <file>` entrypoint
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$(pwd)/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

fixdir=$(mktemp -d)
trap 'rm -rf "$fixdir"' EXIT

cat > "$fixdir/src_meta_fix.clj" <<'EOF'
(ns src-meta-fix)
(defn fixture-fn [x] x)
(println [(:line (meta (var fixture-fn))) (clojure.string/includes? (str (:file (meta (var fixture-fn)))) "src_meta_fix")])
EOF
assert_eq 'fixture_line_file' "$("$BIN" "$fixdir/src_meta_fix.clj" 2>&1 || true)" '[2 true]'

cat > "$fixdir/main.clj" <<'EOF'
(defn built-fn "built doc" [x] (inc x))
(println [(:doc (meta (var built-fn))) (pos? (or (:line (meta (var built-fn))) 0))])
EOF
(cd "$fixdir" && "$BIN" build main.clj -o app >/dev/null 2>&1)
assert_eq 'aot_meta_survives' "$("$fixdir/app" 2>&1 | tail -1)" '[built doc true]'

echo "OK — phase15_var_source_meta (2 process cases) green"
