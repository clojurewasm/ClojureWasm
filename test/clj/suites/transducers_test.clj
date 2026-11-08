;; Transducer surface — migrated from test/e2e/phase14_transducers.sh.
;;
;; Every case here asserted a VALUE in the bash script (one `cljw -e` process
;; per expression, stdout string-compared). Running them in-process keeps the
;; same expectations; the only shape change is that the two print-form cases
;; (`ed_print`) compare `pr-str` output instead of a process's stdout.
;;
;; Discovered automatically by test/clj/run_suites.clj (directory listing).
(ns suites.transducers-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- cycle 1: the reduced sentinel surface ---
(deftest reduced-sentinel
  (testing "reduced? discriminates the sentinel"
    (is (= true (reduced? (reduced 5))))
    (is (= false (reduced? 5))))
  (testing "unreduced unwraps, and passes a plain value through"
    (is (= 7 (unreduced (reduced 7))))
    (is (= 7 (unreduced 7))))
  (testing "ensure-reduced wraps once and is idempotent"
    (is (= true (reduced? (ensure-reduced 5))))
    (is (= 9 (unreduced (ensure-reduced (reduced 9))))))
  (testing "deref on a Reduced yields the wrapped value"
    (is (= 42 @(reduced 42)))))

(deftest reduce-early-termination
  (is (= 6 (reduce (fn [acc x] (if (>= acc 6) (reduced acc) (+ acc x)))
                   0 [1 2 3 4 5]))))

;; --- cycle 2: transducer arities + completing + transduce ---
(deftest transduce-arities
  (is (= 9 (transduce (map inc) + [1 2 3])))
  (is (= 6 (transduce (filter even?) + 0 [1 2 3 4])))
  (is (= 6 (transduce (comp (map inc) (filter even?)) + 0 [1 2 3 4])))
  (is (= [2 3 4] (transduce (map inc) (completing conj) [] [1 2 3])))
  (is (= 12 (transduce (remove odd?) + 0 [1 2 3 4 5 6])))
  (is (= 6 (transduce (keep (fn [x] (if (even? x) x nil))) + 0 [1 2 3 4]))))

;; --- the transducer arities must NOT break the lazy collection arities ---
(deftest lazy-collection-arities
  (is (= [2 3 4] (into [] (map inc [1 2 3]))))
  (is (= [2 4] (into [] (filter even? [1 2 3 4]))))
  (testing "an infinite lazy source stays lazy"
    (is (= 1 (first (map inc (iterate inc 0)))))))

;; --- cycle 3a: conj arities + 3-arg (transducer-aware) into ---
(deftest conj-arities
  (is (= [] (conj)))
  (is (= [1 2] (conj [1 2])))
  (is (= [1 2 3 4] (conj [1] 2 3 4))))

(deftest into-arities
  (testing "2-arg into"
    (is (= [1 2 3] (into [] [1 2 3])))
    (is (= {:a 1 :b 2} (into {} [[:a 1] [:b 2]]))))
  (testing "3-arg into applies the transducer"
    (is (= [2 3 4] (into [] (map inc) [1 2 3])))
    (is (= [3 5] (into [] (comp (filter even?) (map inc)) [1 2 3 4])))
    (is (= #{2 3 4} (into #{} (map inc) [1 1 2 3])))))

;; --- cycle 3b: stateful transducers ---
(deftest stateful-transducers
  (is (= [1 2 3] (into [] (take 3) [1 2 3 4 5])))
  (is (= [3 4 5] (into [] (drop 2) [1 2 3 4 5])))
  (is (= [[0 :a] [1 :b] [2 :c]]
         (into [] (map-indexed (fn [i x] [i x])) [:a :b :c])))
  (is (= [2 3] (into [] (comp (map inc) (take 2)) [1 2 3 4 5])))
  (is (= [20 30] (into [] (comp (drop 1) (take 2)) [10 20 30 40])))
  (testing "take's ensure-reduced stops early even on an INFINITE lazy source"
    (is (= [0 1 2] (into [] (take 3) (iterate inc 0)))))
  (testing "regression: the lazy collection arities still work"
    (is (= [1 2 3] (into [] (take 3 [1 2 3 4 5]))))
    (is (= [3 4 5] (into [] (drop 2 [1 2 3 4 5]))))))

;; --- cycle 4: dedupe / distinct / partition-all + cat ---
(deftest dedupe-distinct-partition-cat
  (is (= [1 2 3 1] (into [] (dedupe) [1 1 2 2 2 3 1 1])))
  (is (= [1 2 3 4] (into [] (distinct) [1 2 1 3 2 4])))
  (is (= [[1 2] [3 4] [5]] (into [] (partition-all 2) [1 2 3 4 5])))
  ;; `=` alone does NOT pin the inner type — (= [[1 2]] [(seq [1 2])]) is true —
  ;; and clj's partition xforms produce VECTORS. The bash case this replaced
  ;; compared the printed form, which pinned that; assert it directly.
  (is (every? vector? (into [] (partition-all 2) [1 2 3 4 5])))
  (is (= [1 2 3 4 5] (into [] cat [[1 2] [3 4] [5]])))
  (is (= [2 3 4 5] (into [] (comp cat (map inc)) [[1 2] [3 4]])))
  (testing "preserving-reduced propagates the early stop through cat"
    (is (= [1 2 3] (into [] (comp cat (take 3)) [[1 2] [3 4] [5 6]]))))
  (is (= [2 4] (into [] (comp (map inc) (filter even?) (distinct))
                    [1 1 2 3 3 4]))))

;; --- mapcat's 1-arg xform = (comp (map f) cat) (D-177) ---
(deftest mapcat-transducer
  (is (= [1 1 2 2 3 3] (into [] (mapcat (fn [x] [x x])) [1 2 3])))
  (is (= 4 (transduce (mapcat range) + 0 [1 2 3]))))

;; --- cycle 5: halt-when ---
(deftest halt-when-xform
  (testing "a match short-circuits and returns the matching input"
    (is (= -3 (transduce (halt-when neg?) conj [] [1 2 -3 4]))))
  (testing "no match reduces normally"
    (is (= [1 2 3] (transduce (halt-when neg?) conj [] [1 2 3]))))
  (testing "the retf arity builds the halt value from the accumulator"
    (is (= [1 2 -3] (transduce (halt-when neg? (fn [r i] (conj r i)))
                               conj [] [1 2 -3 4]))))
  (testing "halt-when inside a comp"
    (is (= 5 (transduce (comp (map inc) (halt-when (fn [x] (> x 4))))
                        conj [] [1 2 3 4])))))

;; --- cycle 6 (D-160): `sequence`, the lazy push→pull bridge ---
;; The iterate/take cases are the laziness guard: an eager
;; (seq (into [] xform coll)) would hang.
(deftest sequence-xform
  (is (= [2 3 4] (into [] (sequence (map inc) [1 2 3]))))
  (is (= 1 (first (sequence (map inc) (iterate inc 0)))))
  (is (= [0 1] (into [] (sequence (take 2) (iterate inc 0)))))
  (is (= [3 5] (into [] (sequence (comp (filter even?) (map inc)) [1 2 3 4]))))
  (is (= [[1 2] [3 4] [5]] (into [] (sequence (partition-all 2) [1 2 3 4 5]))))
  (is (every? vector? (into [] (sequence (partition-all 2) [1 2 3 4 5]))))
  (is (= [1 1 2 2 3 3] (into [] (sequence (mapcat (fn [x] [x x])) [1 2 3]))))
  (is (= [1 2 3] (into [] (sequence [1 2 3]))))
  (is (= [] (into [] (sequence (map inc) [])))))

;; --- D-160 residual: multi-coll `sequence` walks tuples in lockstep ---
(deftest sequence-multi-coll
  (is (= [5 7 9] (into [] (sequence (map +) [1 2 3] [4 5 6]))))
  (is (= [[1 3 5] [2 4 6]] (into [] (sequence (map vector) [1 2] [3 4] [5 6]))))
  (testing "stops at the shortest collection"
    (is (= [5 7] (into [] (sequence (map +) [1 2 3] [4 5]))))))

;; --- cycle 7 (D-160 / ADR-0067): `eduction` is a re-iterable
;; reducible+seqable deftype, NOT an alias for sequence ---
(deftest eduction-basics
  (is (= [2 4] (into [] (eduction (map inc) (filter even?) [1 2 3 4]))))
  (is (= 9 (reduce + (eduction (map inc) [1 2 3]))))
  (is (= 109 (reduce + 100 (eduction (map inc) [1 2 3]))))
  (is (= ["2" "3" "4"] (into [] (map str (eduction (map inc) [1 2 3]))))))

(deftest eduction-is-re-iterable
  ;; The contract test: a cached lazy-seq would count 3, the re-iterable
  ;; eduction counts 6.
  (let [c (atom 0)
        e (eduction (map (fn [x] (swap! c inc) x)) [1 2 3])]
    (reduce + 0 e)
    (reduce + 0 e)
    (is (= 6 @c))))

;; --- D-189: first/rest/next coerce a Seqable-only deftype via seq ---
(deftest eduction-seq-coercion
  (is (= 6 (first (eduction (map inc) [5 6 7]))))
  (is (= [7 8] (into [] (rest (eduction (map inc) [5 6 7])))))
  (is (= [7 8] (into [] (next (eduction (map inc) [5 6 7]))))))

;; --- D-190 / ADR-0068: an eduction prints as its realized seq and is
;; sequential? (was #Eduction[..] / false) ---
(deftest eduction-print-and-sequential
  (is (= "(2 3 4)" (pr-str (eduction (map inc) [1 2 3]))))
  (is (= true (sequential? (eduction (map inc) [1 2 3])))))

;; --- §A26 sweep: single-arity xforms D-177's discharge had missed ---
(deftest single-arity-xform-sweep
  (is (= [1 2] (into [] (take-while pos?) [1 2 -1 3])))
  (is (= [1 3 5] (into [] (take-nth 2) [1 2 3 4 5])))
  (is (= [:b :d] (into [] (keep-indexed (fn [i x] (when (odd? i) x)))
                       [:a :b :c :d])))
  (is (= [:a 2 :a] (into [] (replace {1 :a}) [1 2 1])))
  (is (= [[1 1] [2] [3]] (into [] (partition-by odd?) [1 1 2 3])))
  (is (every? vector? (into [] (partition-by odd?) [1 1 2 3])))
  (testing "partition-by flushes its pending group under an early stop"
    (is (= [[1 1] [2]] (into [] (comp (partition-by odd?) (take 2))
                             [1 1 2 3 5])))
    ;; the flushed group must be a vector too, not a seq
    (is (every? vector? (into [] (comp (partition-by odd?) (take 2))
                              [1 1 2 3 5])))))
