#!/usr/bin/env bash
# test/e2e/phase14_core_surface_protocols.sh — AD-057 pin.
#
# cljw's `clojure.core` publishes protocol names (ISeq, ILookup, Seqable, …)
# and their `-name` methods (-first, -count, -assoc, …) that JVM Clojure does
# not have as vars, because cljw has no Java: where mainline exposes the
# `clojure.lang.*` INTERFACES a deftype implements, cljw exposes protocols
# (ADR-0007 Option beta / ADR-0059), the ClojureScript convention.
#
# This pin locks the reason. The 2026-08-04 audit read that surface as leaked
# internal helpers and drafted a cleanup that would have broken every deftype
# against a host interface. If a future cleanup makes these private, THIS
# breaks first and says why.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

# 1. The protocol and its method are both resolvable from user code.
got=$("$BIN" -e '(println [(some? (resolve (quote ISeq))) (some? (resolve (quote -first)))])' 2>&1 | sed -n 1p)
[[ "$got" == "[true true]" ]] || fail "ISeq / -first not resolvable: got '$got'"
echo "PASS core-surface-protocol-resolvable -> $got"

# 2. A user deftype implements the protocol by those names and the ordinary
#    clojure.core fn dispatches to it. This is what the surface is FOR.
got=$("$BIN" - <<'EOF' 2>&1 | sed -n 1p
(deftype TwoSeq []
  ISeq
  (-first [_] :a)
  (-rest [_] nil))
(println (first (TwoSeq.)))
EOF
)
[[ "$got" == ":a" ]] || fail "deftype against ISeq did not dispatch through first: got '$got'"
echo "PASS core-surface-deftype-dispatch -> $got"

# 3. A lookup protocol, to show it is not one special case.
got=$("$BIN" - <<'EOF' 2>&1 | sed -n 1p
(deftype OneKey []
  ILookup
  (-lookup [_ k] (when (= k :hit) 42)))
(println [(get (OneKey.) :hit) (get (OneKey.) :miss)])
EOF
)
[[ "$got" == "[42 nil]" ]] || fail "deftype against ILookup did not dispatch through get: got '$got'"
echo "PASS core-surface-ilookup-dispatch -> $got"

# 4. The documented extra-surface set is exactly what ships.
bash scripts/check_core_surface.sh >/dev/null || fail "check_core_surface reported drift"
echo "PASS core-surface-set-matches-ledger"

echo "OK — phase14_core_surface_protocols (4 cases) green"
