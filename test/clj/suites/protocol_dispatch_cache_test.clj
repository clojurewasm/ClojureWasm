;; ADR-0206: every ProtocolFn memoises (receiver descriptor, protocol
;; generation) -> resolved method. These pins call a protocol fn FIRST, so the
;; cache is filled, then change what the call must resolve to, then call
;; again. A stale memo answers the old value. Every expected value is the
;; JVM's (clojure -M); the cache must be invisible.
(ns suites.protocol-dispatch-cache-test
  (:require [clojure.test :refer [deftest is]]))

(defprotocol PCache (pc [x]))

(defrecord CacheA [v])
(defrecord CacheB [v])

;; --- extend after the first call: a miss that raised must not stick ---
(deftest extend-type-after-a-failed-first-call
  (let [a (->CacheA 1)]
    (is (thrown? Exception (pc a)))
    (extend-type CacheA PCache (pc [x] [:a (:v x)]))
    (is (= [:a 1] (pc a)))))

;; --- a re-extend replaces the impl the cache already holds ---
(deftest re-extend-replaces-a-cached-impl
  (extend-type CacheB PCache (pc [_] :first))
  (let [b (->CacheB 1)]
    (is (= :first (pc b)))
    (is (= :first (pc b)))
    (extend-type CacheB PCache (pc [_] :second))
    (is (= :second (pc b)))))

;; --- an Object default cached for a type is displaced by a later
;; type-specific extension ---
(defprotocol PFallback (pf [x]))
(defrecord FallbackR [])
(extend-protocol PFallback Object (pf [_] :object))

(deftest specific-extend-displaces-a-cached-object-default
  (let [r (->FallbackR)]
    (is (= :object (pf r)))
    (is (= :object (pf r)))
    (extend-type FallbackR PFallback (pf [_] :specific))
    (is (= :specific (pf r)))
    (is (= :object (pf "a string still falls back")))))

;; --- one call site alternating receiver types (the slot is monomorphic,
;; so this is the refill path every iteration) ---
(defprotocol PPoly (pp [x]))
(defrecord PolyA [])
(defrecord PolyB [])
(extend-protocol PPoly
  PolyA (pp [_] 1)
  PolyB (pp [_] 10))

(deftest alternating-receivers-at-one-site
  (let [xs (vec (take 100 (cycle [(->PolyA) (->PolyB)])))]
    (is (= 550 (reduce + (map pp xs))))))

;; --- redefining the record: the old vintage keeps its impl, the new one
;; must not be answered from the old vintage's cache entry ---
(defprotocol PRedef (pr-v [x]))
(defrecord RedefR [a])
(extend-protocol PRedef RedefR (pr-v [x] [:old (:a x)]))
(def ^:private old-r (->RedefR 1))
(def ^:private old-answer (pr-v old-r))
(defrecord RedefR [a])
(extend-protocol PRedef RedefR (pr-v [x] [:new (:a x)]))
(def ^:private new-r (->RedefR 2))

(deftest redefined-record-dispatches-per-vintage
  (is (= [:old 1] old-answer))
  (is (= [:new 2] (pr-v new-r)))
  (is (= [:old 1] (pr-v old-r)))
  (is (= [:new 2] (pr-v new-r))))

;; --- re-evaluating defprotocol, then re-extending: clj and bb both keep the
;; extend-type impl across a same-shape defprotocol re-eval (measured: :v1
;; twice), and the re-extend after it must win over the cached :v1 ---
(defprotocol PReproto (rp [x]))
(defrecord ReprotoR [])
(extend-type ReprotoR PReproto (rp [_] :v1))
(def ^:private before-redefine (rp (->ReprotoR)))
(defprotocol PReproto (rp [x]))
(def ^:private after-redefine (rp (->ReprotoR)))

(deftest redefined-protocol-then-re-extend
  (is (= :v1 before-redefine))
  (is (= :v1 after-redefine))
  (extend-type ReprotoR PReproto (rp [_] :v2))
  (is (= :v2 (rp (->ReprotoR)))))

;; --- native receivers share one descriptor per tag ---
(defprotocol PNative (pn [x]))

(deftest extend-a-native-type-after-first-call
  (is (thrown? Exception (pn 1)))
  (extend-protocol PNative Long (pn [x] (inc x)))
  (is (= 2 (pn 1)))
  (extend-protocol PNative Long (pn [x] (dec x)))
  (is (= 0 (pn 1))))

;; --- reify: each reify value carries its own anonymous descriptor ---
(deftest reify-receivers-do-not-alias
  (let [rs (mapv (fn [i] (reify PPoly (pp [_] i))) (range 5))]
    (is (= [0 1 2 3 4] (mapv pp rs)))))
