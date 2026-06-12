#!/usr/bin/env bash
# test/e2e/phase15_marker_protocol.sh — marker (zero-method) protocol membership
# (D-232). A protocol with no methods installs no method_table entry; its
# membership lives only in `protocol_impls` (D-190 / ADR-0068). `satisfies?`
# used to scan only method_table, so a type extending a marker protocol read
# as NOT satisfying it (clj returns true). Fixed: satisfies? also scans
# protocol_impls. clj-grounded. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# marker protocol extended via the defrecord body
assert_eq 'marker-defrecord' \
  "$("$BIN" -e '(defprotocol M "marker") (defrecord RM [] M) (satisfies? M (->RM))' 2>&1 | tail -1)" \
  'true'

# marker protocol extended via extend-type
assert_eq 'marker-extend-type' \
  "$("$BIN" -e '(defprotocol M) (defrecord RM []) (extend-type RM M) (satisfies? M (->RM))' 2>&1 | tail -1)" \
  'true'

# a non-member is still false (no false positive)
assert_eq 'non-member-false' \
  "$("$BIN" -e '(defprotocol M "marker") (defrecord Other []) (satisfies? M (->Other))' 2>&1 | tail -1)" \
  'false'

# regression: a method-bearing protocol still satisfies + dispatches
assert_eq 'method-proto-regress' \
  "$("$BIN" -e '(defprotocol G (g [x])) (defrecord R [n] G (g [x] n)) [(satisfies? G (->R 1)) (g (->R 7))]' 2>&1 | tail -1)" \
  '[true 7]'

echo "OK — phase15_marker_protocol (4 cases) green"
