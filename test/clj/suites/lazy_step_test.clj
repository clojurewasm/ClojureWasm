;; Native lazy producers (O-110): one-coll map, filter, take and iterate
;; realize their nodes in Zig (lazy_step.zig) instead of through an
;; interpreted arity-0 closure. The node shape is clj's own, so WHAT is
;; realized and WHEN must not change. Every count below was measured on bb
;; (clj semantics): an unchunked source (iterate, a list) realizes one
;; element per node, a chunked one (a range, a vector) a chunk of 32.
(ns suites.lazy-step-test
  (:require [clojure.test :refer [deftest is]]))

(defn- counting [log f] (fn [x] (swap! log inc) (f x)))

(deftest iterate-runs-f-only-for-reached-elements
  (let [log (atom 0)
        s (iterate (counting log inc) 0)]
    (is (= 0 (first s)))
    (is (= 0 @log))                         ; first never calls f
    (is (= 3 (nth s 3)))
    (is (= 3 @log))
    (is (= [0 1 2 3] (vec (take 4 s))))
    (is (= 3 @log))))                       ; realized elements are cached

(deftest map-over-an-unchunked-source-is-one-call-per-node
  (let [log (atom 0)
        m (map (counting log inc) (iterate inc 0))]
    (is (false? (realized? m)))
    (is (= 0 @log))                         ; building the seq calls nothing
    (is (= 1 (first m)))
    (is (= 1 @log))
    (is (= [1 2 3] (vec (take 3 m))))
    (is (= 3 @log)))
  (let [log (atom 0)]
    (is (= '(2 3 4) (map (counting log inc) '(1 2 3))))
    (is (= 3 @log))))

(deftest filter-over-an-unchunked-source-stops-at-the-first-survivor
  (let [log (atom 0)
        s (filter (counting log odd?) (iterate inc 0))]
    (is (= 1 (first s)))
    (is (= 2 @log))                         ; 0 rejected, 1 kept
    (is (= [1 3 5] (vec (take 3 s))))
    (is (= 6 @log)))
  ;; a long run of rejects realizes in one step and does not grow the stack
  (is (= 100000 (first (filter #(= % 100000) (iterate inc 0)))))
  (is (= '() (filter odd? '(2 4 6))))
  (is (nil? (seq (filter odd? (take 100000 (iterate (partial + 2) 0)))))))

(deftest chunked-sources-still-realize-a-chunk-per-node
  (let [log (atom 0)]
    (is (= 0 (first (map (counting log identity) (range 100)))))
    (is (= 32 @log)))
  (let [log (atom 0)]
    (is (= 1 (first (filter (counting log odd?) (range 100)))))
    (is (= 32 @log)))
  (let [log (atom 0)]
    ;; an all-rejected chunk is skipped inside the same realization
    (is (= 40 (first (filter (counting log #(>= % 40)) (range 100)))))
    (is (= 64 @log)))
  (is (true? (chunked-seq? (seq (map inc (range 40))))))
  (is (true? (chunked-seq? (seq (filter odd? (range 40)))))))

(deftest take-counts-down-like-clj
  (let [log (atom 0)
        s (take 3 (map (counting log inc) (iterate inc 0)))]
    (is (= 0 @log))
    (is (= [1 2 3] (vec s)))
    (is (= 3 @log)))                        ; the element after n is never reached
  (is (= '() (take 0 (iterate inc 0))))
  (is (= '() (take -1 [1 2])))
  (is (= [1 2] (vec (take 5 [1 2]))))
  (is (= [0 1 2] (vec (take 2.5 (range 10)))))  ; a non-integer n counts down too
  (is (= [0 1] (vec (take 9007199254740993 [0 1]))))
  (is (= '() (take -9007199254740993 [0 1])))
  (is (= 2500000000 (reduce + (take 50000 (filter odd? (map #(* 1 %) (iterate inc 0))))))))

(deftest a-throwing-step-propagates
  (let [m (map (fn [x] (throw (ex-info "boom" {:x x}))) (iterate inc 7))]
    (is (= {:x 7} (try (first m) (catch Exception e (ex-data e)))))))

(deftest native-nodes-behave-as-lazy-seqs
  (let [m (map inc (iterate inc 0))]
    (is (instance? clojure.lang.LazySeq m))
    (is (nil? (meta m)))
    (is (= {:a 1} (meta (with-meta m {:a 1}))))
    (is (= 1 (first (with-meta m {:a 1}))))
    (is (= '(2 3 4) (take 3 (rest (map inc (iterate inc 0)))))))
  (is (= "(1 2 3)" (pr-str (take 3 (map inc (iterate inc 0))))))
  (is (= [2 4] (into [] (comp (map inc) (filter even?)) (take 4 (iterate inc 0)))))
  (is (= 2500 (reduce + (map inc (filter even? (take 100 (iterate inc 0))))))))
