#!/usr/bin/env bash
# test/e2e/phase15_new_ctor.sh — the (new Classname args…) constructor special
# form (D-232). Equivalent to the (Classname. args…) sugar; lowers to the same
# constructor InteropCallNode (so both backends handle it). cljw had only the
# trailing-dot sugar. Surfaced by clojure.test-helper:97 `(new Exception …)`.
# clj-grounded (corpus new_ctor). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# (new Exception msg) constructs; .getMessage reads it back
assert_eq 'new-exception' \
  "$("$BIN" -e '(.getMessage (new Exception "boom"))' 2>&1 | tail -1)" \
  '"boom"'

# (new …) and (… .) sugar are equivalent
assert_eq 'new-eq-sugar' \
  "$("$BIN" -e '[(.getMessage (new Exception "x")) (.getMessage (Exception. "x"))]' 2>&1 | tail -1)" \
  '["x" "x"]'

# the constructed value is an instance of the class
assert_eq 'new-instance' \
  "$("$BIN" -e '(instance? Exception (new RuntimeException "r"))' 2>&1 | tail -1)" \
  'true'

# (new) with no class symbol is a clean error, not a crash
assert_eq 'new-no-class' \
  "$("$BIN" -e '(new)' 2>&1 | tail -1 | grep -c 'not yet supported\|requires a class' | tr -d ' ')" \
  '1'

echo "OK — phase15_new_ctor (4 cases) green"
