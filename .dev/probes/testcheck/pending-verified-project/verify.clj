(ns verify
  (:require [clojure.test.check :as tc]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [clojure.test.check.random :as random]
            [clojure.test.check.rose-tree :as rose]))

;; test.check is the generator engine every malli.generator consumer sits on.
;; Exercise the four surfaces a property suite actually leans on: seeded
;; determinism, a passing property, a FAILING property that must shrink to the
;; minimal counterexample (the rose-tree path), and the seedless RNG.

(defn- seeded-determinism []
  (let [a (gen/sample-seq gen/small-integer)
        s1 (gen/sample gen/nat 20)
        stable #(select-keys % [:num-tests :seed :pass? :result])
        r1 (tc/quick-check 50 (prop/for-all [i gen/nat] (>= i 0)) :seed 42)
        r2 (tc/quick-check 50 (prop/for-all [i gen/nat] (>= i 0)) :seed 42)]
    (assert (seq a))
    (assert (= 20 (count s1)))
    (assert (every? #(>= % 0) s1))
    (assert (= (stable r1) (stable r2)) "same seed must yield the same quick-check result")
    (assert (= 42 (:seed r1)))
    (assert (true? (:pass? r1)))))

(defn- passing-property []
  (let [r (tc/quick-check 100 (prop/for-all [v (gen/vector gen/small-integer)]
                                            (= (count v) (count (reverse v))))
                          :seed 7)]
    (assert (true? (:pass? r)))
    (assert (= 100 (:num-tests r)))))

(defn- shrinking []
  ;; Every int < 10 — false. Shrinking must land on exactly 10, the minimal
  ;; counterexample. A broken rose tree still FAILS the property but reports a
  ;; large unshrunk witness, so asserting the shrunk value is what has teeth.
  (let [r (tc/quick-check 200 (prop/for-all [i gen/nat] (< i 10)) :seed 3)]
    (assert (false? (:pass? r)))
    (assert (= [10] (-> r :shrunk :smallest))
            (str "expected minimal counterexample [10], got "
                 (pr-str (-> r :shrunk :smallest))))))

(defn- rose-tree-direct []
  (let [t (rose/pure 5)]
    (assert (= 5 (rose/root t)))
    (assert (empty? (rose/children t))))
  ;; `for` inside rose-tree runs in a namespace that :refer-clojure :excludes
  ;; `seq`; a macro expansion emitting a BARE `seq` binds the shadow and yields
  ;; nil elements instead of raising.
  (let [t (rose/zip vector [(rose/pure 1) (rose/pure 2)])]
    (assert (= [1 2] (rose/root t)))))

(defn- seedless-rng []
  ;; gen/generate and gen/sample-seq with no seed go through
  ;; clojure.test.check.random/make-random's 0-arity, i.e. the ThreadLocal path.
  (let [rng (random/make-random)
        [r1 r2] (random/split rng)]
    (assert (integer? (random/rand-long rng)))
    (assert (not= (random/rand-long r1) (random/rand-long r2)))
    (assert (integer? (gen/generate gen/small-integer)))
    (assert (= 5 (count (take 5 (gen/sample-seq gen/nat)))))))

(defn -main [& _]
  (seeded-determinism)
  (passing-property)
  (shrinking)
  (rose-tree-direct)
  (seedless-rng)
  (println "OK test.check — seeded determinism, passing + failing property, shrink-to-minimal, rose-tree zip, seedless RNG"))
