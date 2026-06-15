#!/usr/bin/env bash
# test/e2e/phase14_extend_protocol_targets.sh
#
# ADR-0114 — extend-protocol TARGET resolution + dispatch:
#  - Object extension is a universal fallback (nil excluded; clj-faithful).
#  - host_inert java.util.Map as TARGET is a load-only NO-OP (AD-023): cljw maps
#    are not java.util.Map, so the impl never dispatches (falls to Object).
#  - clojure.lang IPersistentVector / ISeq / Named distribute to native tags.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
run() { "$BIN" -e "$1" 2>/dev/null; }

# Object is a universal default; nil is NOT an Object (extended separately).
assert_eq 'object_fallback' \
  "$(run '(do (defprotocol P (m [x])) (extend-protocol P Object (m [x] (str "o:" x)) nil (m [x] "nil")) [(m 5) (m "s") (m :k) (m nil)])')" \
  '["o:5" "o:s" "o::k" "nil"]'

# java.util.Map as a TARGET is inert (AD-023): (m {}) falls to Object, NOT :map.
assert_eq 'map_target_inert' \
  "$(run '(do (defprotocol P (m [x])) (extend-protocol P java.util.Map (m [x] :map) Object (m [x] :obj)) (m {:a 1}))')" \
  ':obj'

# clojure.lang interfaces distribute to the native tags.
assert_eq 'native_interface_dispatch' \
  "$(run '(do (defprotocol R (rh [x])) (extend-protocol R IPersistentVector (rh [x] (str "V" (count x))) ISeq (rh [x] (str "S" (count x))) Named (rh [x] (str "N" (name x)))) [(rh [:a :b]) (rh (map inc [1 2 3])) (rh :kw) (rh (quote sy))])')" \
  '["V2" "S3" "Nkw" "Nsy"]'

# D-317: an IPersistentVector-extended protocol reaches a MapEntry too (a MapEntry
# IS-A IPersistentVector — clj-verified). The extend-target set now derives from the
# instance? membership SSOT {vector, map_entry}; before the 2026-06-15 unify it was
# {vector}-only and a (first map) MapEntry mis-dispatched to the Object fallback.
assert_eq 'ipv_reaches_map_entry' \
  "$(run '(do (defprotocol P (m [x])) (extend-protocol P clojure.lang.IPersistentVector (m [x] (str "V" (count x)))) [(m [1 2]) (m (first {:a 1}))])')" \
  '["V2" "V2"]'
