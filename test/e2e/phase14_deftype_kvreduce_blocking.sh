#!/usr/bin/env bash
# test/e2e/phase14_deftype_kvreduce_blocking.sh — the D-400 marker-family
# remainder: clojure.lang.IKVReduce (reduce-kv dispatch), IBlockingDeref
# (3-arity timed deref on deftypes + native future/promise), Indexed 3-arity
# not-found nth on deftypes, and IFn applyTo registration. All expected
# values oracle-verified against clj 2026-06-13.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype KvBag [m]
  clojure.lang.IKVReduce
  (kvreduce [_ f init] (reduce (fn [acc [k v]] (f acc k v)) init (seq m))))
(prn (reduce-kv (fn [acc k v] (assoc acc v k)) {} (->KvBag {:a 1 :b 2})))
(prn (reduce-kv (fn [acc k v] (+ acc v)) 0 (->KvBag {:a 1 :b 2})))
(deftype TimedBox [v]
  clojure.lang.IBlockingDeref
  (deref [_ ms timeout-val] (if (neg? ms) timeout-val v))
  clojure.lang.IDeref
  (deref [_] v))
(prn (deref (->TimedBox 42) 10 :timeout))
(prn (deref (->TimedBox 42) -1 :timeout))
(prn @(->TimedBox 42))
(deftype Idx [n]
  clojure.lang.Indexed
  (nth [_ i] (* i n))
  (nth [_ i nf] (if (< i 3) (* i n) nf)))
(prn (nth (->Idx 10) 2))
(prn (nth (->Idx 10) 9 :nf))
(deftype CallMe []
  clojure.lang.IFn
  (invoke [_ a] [:one a])
  (invoke [_ a b] [:two a b])
  (applyTo [this args] (case (count args) 1 (this (first args)) 2 (this (first args) (second args)))))
(prn ((->CallMe) 1))
(prn (apply (->CallMe) [1 2]))
(prn (deref (future 7) 50 :timeout))
(prn (deref (promise) 30 :timeout))
(let [p (promise)] (deliver p :pv) (prn (deref p 30 :timeout)))
EOF
) || true
want='{1 :a, 2 :b}
3
42
:timeout
42
20
:nf
[:one 1]
[:two 1 2]
7
:timeout
:pv'
assert_eq 'kvreduce_blocking_indexed_applyto' "$got" "$want"

# java.lang.Comparable deftype (instaparse's AutoFlattenSeq): compare +
# the natural sort consult it; IPersistentVector as a supertype-WITH-METHODS
# (the D-400 composite, ADR-0134-pulled) registers assoc/assocN/length.
got=$("$BIN" - <<'CLJ' 2>/dev/null
(deftype Cmp [v]
  java.lang.Comparable
  (compareTo [self that] (compare v (.-v that))))
(prn (compare (->Cmp 1) (->Cmp 2)))
(prn (mapv (fn [c] (.-v c)) (sort [(->Cmp 2) (->Cmp 1) (->Cmp 0)])))
(deftype MiniVec [v]
  clojure.lang.Counted
  (count [_] (count v))
  clojure.lang.IPersistentVector
  (assoc [self i val] (MiniVec. (assoc v i val)))
  (assocN [self i val] (MiniVec. (.assocN v i val)))
  (length [_] (count v)))
(prn (count (->MiniVec [1 2 3])))
(prn (.-v (.assocN (->MiniVec [1 2 3]) 0 9)))
CLJ
) || true
want='-1
[0 1 2]
3
[9 2 3]'
assert_eq 'comparable_ipv_supertype' "$got" "$want"

# A BARE CharSequence supertype (instaparse's Segment; java.lang is
# JVM-auto-imported so libs declare it unqualified) registers + its own
# dot-calls dispatch (oracle-verified).
got=$("$BIN" - <<'CLJ' 2>/dev/null
(deftype Seg [s offset cnt]
  CharSequence
  (length [this] cnt)
  (charAt [this i] (.charAt s (+ offset i))))
(def g (->Seg "hello" 1 3))
(prn [(.length g) (.charAt g 0)])
CLJ
) || true
assert_eq 'charsequence_supertype' "$got" '[3 \e]'

# reduce-kv on a RECORD (no IKVReduce) still takes the keys fallback.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord R [a b])
(prn (reduce-kv (fn [acc k v] (assoc acc v k)) {} (->R 1 2)))
EOF
) || true
assert_eq 'reduce_kv_record_fallback' "$got" '{1 :a, 2 :b}'

echo "OK — phase14_deftype_kvreduce_blocking (4 cases) green"
