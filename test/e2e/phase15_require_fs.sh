#!/usr/bin/env bash
# test/e2e/phase15_require_fs.sh — filesystem `require` (D-158, ADR-0084,
# ADR-0189) as configured by the PROCESS: the `-cp <roots>` argv and
# $CLJW_PATH decide where `require` looks, and the probe order (.cljw > .clj >
# .cljc within a root, earlier root first) is a property of those roots. Each
# case therefore starts a cljw with its own classpath. A disk lib loaded
# in-process (load-file + run its deftest suite) and the missing-lib error live
# in test/clj/suites/concurrency_host_test.clj (p15-require-fs).
# e2e-process-boundary: the classpath under test is the -cp argv / CLJW_PATH environment of a fresh process
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
CP="test/e2e/fixtures/cljwlib"
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'cp-load'  "$("$BIN" -cp "$CP" -e '(require (quote [demo.math :as m])) (m/square 7)' 2>&1 | tail -1)" '49'
assert_eq 'env-path' "$(CLJW_PATH="$CP" "$BIN" -e '(require (quote [demo.math :as m])) (m/cube 4)' 2>&1 | tail -1)" '64'
assert_eq 'use-disk' "$("$BIN" -cp "$CP" -e '(ns foo (:use demo.math)) (square 6)' 2>&1 | tail -1)" '36'

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# embedded clojure.string NOT shadowed by a stray on-disk file
mkdir -p "$WORK/shadow/clojure"; printf '(ns clojure.string) (def upper-case :HIJACKED)\n' > "$WORK/shadow/clojure/string.clj"
assert_eq 'no-shadow' "$("$BIN" -cp "$WORK/shadow" -e '(clojure.string/upper-case "hi")' 2>&1 | tail -1)" '"HI"'
# cycle a->b->a -> Cyclic load dependency (message + caret = 2, D-555)
mkdir -p "$WORK/cyc/cyc"
printf '(ns cyc.a (:require [cyc.b]))\n' > "$WORK/cyc/cyc/a.clj"
printf '(ns cyc.b (:require [cyc.a]))\n' > "$WORK/cyc/cyc/b.clj"
assert_eq 'cycle' "$("$BIN" -cp "$WORK/cyc" -e '(require (quote cyc.a))' 2>&1 | grep -c 'Cyclic load dependency')" '2'

# --- .cljw extension resolution (ADR-0189) ---
EXT="$WORK/ext"; EXT2="$WORK/ext2"; mkdir -p "$EXT/ext" "$EXT2/ext"
printf '(ns ext.only) (def who :from-cljw)\n' > "$EXT/ext/only.cljw"
assert_eq 'cljw-only'  "$("$BIN" -cp "$EXT" -e '(require (quote ext.only)) ext.only/who' 2>&1 | tail -1)" ':from-cljw'
printf '(ns ext.both) (def who :from-cljw)\n'  > "$EXT/ext/both.cljw"
printf '(ns ext.both) (def who :from-clj)\n'   > "$EXT/ext/both.clj"
printf '(ns ext.both) (def who :from-cljc)\n'  > "$EXT/ext/both.cljc"
assert_eq 'cljw-wins'   "$("$BIN" -cp "$EXT" -e '(require (quote ext.both)) ext.both/who' 2>&1 | tail -1)" ':from-cljw'
printf '(ns ext.pair) (def who :from-clj)\n'   > "$EXT/ext/pair.clj"
printf '(ns ext.pair) (def who :from-cljc)\n'  > "$EXT/ext/pair.cljc"
assert_eq 'clj-over-cljc' "$("$BIN" -cp "$EXT" -e '(require (quote ext.pair)) ext.pair/who' 2>&1 | tail -1)" ':from-clj'
printf '(ns ext.mixed (:require [ext.pair :as p])) (def who p/who)\n' > "$EXT/ext/mixed.cljw"
assert_eq 'cljw-requires-clj' "$("$BIN" -cp "$EXT" -e '(require (quote ext.mixed)) ext.mixed/who' 2>&1 | tail -1)" ':from-clj'
# an EARLIER classpath root wins even when a later root holds the .cljw
printf '(ns ext.rooted) (def who :from-root2-cljw)\n' > "$EXT2/ext/rooted.cljw"
printf '(ns ext.rooted) (def who :from-root1-clj)\n'  > "$EXT/ext/rooted.clj"
assert_eq 'root-beats-ext' "$("$BIN" -cp "$EXT:$EXT2" -e '(require (quote ext.rooted)) ext.rooted/who' 2>&1 | tail -1)" ':from-root1-clj'

echo "OK — phase15_require_fs (10 classpath cases) green"
