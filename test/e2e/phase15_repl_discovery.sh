#!/usr/bin/env bash
# test/e2e/phase15_repl_discovery.sh
#
# clojure.repl's REPL-discovery helpers — since D-513 they live in the bundled
# `clojure.repl` (their clj home; the early in-core copies were removed with
# D-305/D-513): `dir-fn` / `dir` / `apropos` (+ doc/find-doc, covered by
# phase16_clojure_repl.sh). `dir-fn` matches clj exactly; `apropos` scans
# all-ns (the exact qualified-symbol set is ns-set-dependent, so assert
# containment, not equality).
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_contains() { local n="$1" h="$2" needle="$3"; case "$h" in *"$needle"*) echo "PASS $n ⊇ $needle";; *) fail "$n: '$h' missing '$needle'";; esac; }

# dir-fn — deterministic, == clj.
assert_eq 'dir_fn_set' "$("$BIN" -e '(do (require (quote [clojure.set]) (quote [clojure.repl])) (clojure.repl/dir-fn (quote clojure.set)))')" \
  '(difference index intersection join map-invert project rename rename-keys select subset? superset? union)'

# dir — prints each public var, one per line, sorted.
out="$("$BIN" -e '(do (require (quote [clojure.set]) (quote [clojure.repl])) (clojure.repl/dir clojure.set))')"
assert_contains 'dir_first' "$out" 'difference'
assert_contains 'dir_last'  "$out" 'union'

# apropos — string substring match over all-ns publics, fully-qualified, sorted.
ap="$("$BIN" -e '(do (require (quote [clojure.repl])) (prn (clojure.repl/apropos "reduce-kv")))')"
assert_contains 'apropos_kv' "$ap" 'reduce-kv'
# apropos with a regex.
apr="$("$BIN" -e '(do (require (quote [clojure.repl])) (prn (clojure.repl/apropos #"^reductions$")))')"
assert_contains 'apropos_re' "$apr" 'reductions'
# apropos returns a (sorted) seq.
assert_eq 'apropos_empty' "$("$BIN" -e '(do (require (quote [clojure.repl])) (seq? (clojure.repl/apropos "definitely-no-such-var-xyzzy")))')" 'true'

echo "ALL phase15_repl_discovery PASS"
