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

# ADR-0187: a PROTOCOL as the extend target means "every type satisfying it".
# `defprotocol Q` in ns `pt` is named by its generated interface name `pt.Q`.
assert_eq 'protocol_target_dispatch' \
  "$(run '(do (ns pt) (defprotocol Q (qm [x])) (defprotocol P (m [x])) (defrecord R [v] Q (qm [_] :q)) (extend-protocol P pt.Q (m [x] (str "viaQ" (qm x)))) (m (->R 1)))')" \
  '"viaQ:q"'

# ...and it OUTRANKS the Object default, as an interface impl does on the JVM.
assert_eq 'protocol_target_beats_object' \
  "$(run '(do (ns pt2) (defprotocol Q (qm [x])) (defprotocol P (m [x])) (defrecord R [v] Q (qm [_] :q)) (extend-protocol P Object (m [x] :obj) pt2.Q (m [x] :viaQ)) [(m (->R 1)) (m 5)])')" \
  '[:viaQ :obj]'

# A type that does NOT satisfy the target protocol still falls to Object.
assert_eq 'protocol_target_non_satisfier_falls_through' \
  "$(run '(do (ns pt3) (defprotocol Q (qm [x])) (defprotocol P (m [x])) (extend-protocol P Object (m [x] :obj) pt3.Q (m [x] :viaQ)) (m "s"))')" \
  ':obj'

# ORDER-INDEPENDENT: the type is extended to Q AFTER P was extended to Q, so a
# registration-time copy would miss it. Membership is answered at dispatch.
assert_eq 'protocol_target_extend_after' \
  "$(run '(do (ns pt4) (defprotocol Q (qm [x])) (defprotocol P (m [x])) (extend-protocol P pt4.Q (m [x] :viaQ)) (defrecord Late [v] Q (qm [_] :q)) (m (->Late 1)))')" \
  ':viaQ'
