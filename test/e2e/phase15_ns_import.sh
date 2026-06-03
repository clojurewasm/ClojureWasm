#!/usr/bin/env bash
# test/e2e/phase15_ns_import.sh — the `(:import …)` ns directive (D-235).
# Maps a simple class name to its JVM-form FQCN in the ns import table, so a
# bare `(Class. …)` / `Class/method` resolves the imported class (consulted by
# resolveJavaSurface before the java.lang auto-import). Both the single dotted
# symbol `pkg.Class` and the prefix `[pkg C1 C2]` forms are supported. An
# import of a class cljw does not provide loads fine and raises a clean error
# only on USE (not at the directive). Validation-campaign: data/parse/errors/
# api/clearing all open with `(:import …)`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }

# single dotted-symbol import — simple name resolves to the FQCN
assert_eq 'sym-form'   "$("$BIN" -e '(ns a (:import java.util.UUID)) (uuid? (UUID/randomUUID))' 2>&1 | tail -1)" 'true'
# prefix [pkg Class …] import form
assert_eq 'prefix-form' "$("$BIN" -e '(ns a (:import [java.util UUID])) (uuid? (UUID/randomUUID))' 2>&1 | tail -1)" 'true'
# FQCN form keeps working after an import
assert_eq 'fqcn-still'  "$("$BIN" -e '(ns a (:import java.util.UUID)) (uuid? (java.util.UUID/randomUUID))' 2>&1 | tail -1)" 'true'
# an ns with no :import is unaffected
assert_eq 'no-import'   "$("$BIN" -e '(ns z) (+ 1 2)' 2>&1 | tail -1)" '3'
# importing a class cljw lacks LOADS fine (directive accepted)
assert_eq 'unsupp-load' "$("$BIN" -e '(ns y (:import java.util.HashSet)) :loaded' 2>&1 | tail -1)" ':loaded'
# ...but USING it raises a clean (catchable) error, not a silent success
assert_has 'unsupp-use' "$("$BIN" -e '(ns y (:import java.util.HashSet)) (HashSet.)' 2>&1)" "Unable to resolve symbol: 'HashSet'"

echo "OK — phase15_ns_import (6 cases) green"
