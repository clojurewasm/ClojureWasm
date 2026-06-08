#!/usr/bin/env bash
# test/e2e/phase15_reader_conditional.sh — #? reader conditionals (D-232).
# `#?(:clj a :cljs b :default c)` reads ONE branch by platform feature. cljw's
# feature set is {:clj, :default} (it implements Clojure, not ClojureScript), so
# the first :clj/:default branch (left-to-right, clj-faithful) is read; a
# non-matching #? reads as nothing. The .cljc gate for real-world libraries
# (weavejester/medley). No corpus: `clj -M -e` rejects #? without :read-cond
# (a .cljc context); the expected values follow clj semantics. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# :clj branch is selected (cljw implements Clojure semantics)
assert_eq 'clj-branch' \
  "$("$BIN" -e '#?(:clj 1 :cljs 2)' 2>&1 | tail -1)" \
  '1'

# branch order does not matter — :clj wins wherever it is
assert_eq 'clj-branch-reordered' \
  "$("$BIN" -e '#?(:cljs 9 :clj 8)' 2>&1 | tail -1)" \
  '8'

# :default is the fallback when there is no :clj branch
assert_eq 'default-fallback' \
  "$("$BIN" -e '#?(:cljs 1 :default 7)' 2>&1 | tail -1)" \
  '7'

# a non-matching #? inside a collection reads as nothing
assert_eq 'no-match-skips' \
  "$("$BIN" -e '[1 #?(:cljs 2) 3]' 2>&1 | tail -1)" \
  '[1 3]'

# a non-matching #? as the LAST element (before a trailing closer) — the
# boundary case that used to read the `]` as the branch and error
assert_eq 'no-match-trailing' \
  "$("$BIN" -e '[1 #?(:cljs 2)]' 2>&1 | tail -1)" \
  '[1]'

# the .cljc ns shape: `#?` at the tail of the (ns …) form list
assert_eq 'no-match-ns-tail' \
  "$("$BIN" -e '(quote (ns x #?(:cljs :m)))' 2>&1 | tail -1)" \
  '(ns x)'

# --- #?@ splicing: the selected branch's elements are spliced into the
# enclosing collection (real .cljc libs: aero, defun use it) ---
assert_eq 'splice-clj' \
  "$("$BIN" -e '[1 #?@(:clj [2 3]) 4]' 2>&1 | tail -1)" \
  '[1 2 3 4]'
# a non-matching #?@ splices nothing
assert_eq 'splice-no-match' \
  "$("$BIN" -e '[0 #?@(:cljs [9]) 5]' 2>&1 | tail -1)" \
  '[0 5]'
# splice into a list / set works too
assert_eq 'splice-list' \
  "$("$BIN" -e '(list 1 #?@(:clj [2 3]))' 2>&1 | tail -1)" \
  '(1 2 3)'
# top-level #?@ is an error (splice only valid inside a collection)
assert_eq 'splice-top-level' \
  "$("$BIN" -e '#?@(:clj [1 2])' 2>&1 | grep -cm1 'only allowed inside')" \
  '1'

echo "OK — phase15_reader_conditional (10 cases) green"
