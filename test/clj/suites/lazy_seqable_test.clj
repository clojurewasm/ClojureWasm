;; [CLJW-LAZY-SEQABLE] — a lazy-seq body is normalized through the complete
;; Seqable/ISeq boundary (clj LazySeq.realize -> RT.seq parity).
;;
;; JVM oracle: clj 1.12.4, 2026-09-07. AD-067 pins retry/captured-local and
;; inner realization-state differences under ADR-0143's publication invariant.
;; Successful values and first-touch exception classes agree with the JVM.
(ns suites.lazy-seqable-test
  (:require [clojure.test :refer [deftest is testing]]))

(defn- threw? [f]
  (try (f) false (catch Exception _ true)))

(deftest string-body-is-a-char-seq
  (is (= \h (first (lazy-seq "hi"))) "first")
  (is (= '(\i) (rest (lazy-seq "hi"))) "rest")
  (is (= '(\i) (next (lazy-seq "hi"))) "next")
  (is (= '(\h \i) (seq (lazy-seq "hi"))) "seq")
  (is (= 2 (count (lazy-seq "hi"))) "count")
  (is (= 5 (count (lazy-seq "héllo"))) "count counts codepoints, not bytes")
  (is (= [\h \i] (vec (lazy-seq "hi"))) "vec")
  (is (= \i (nth (lazy-seq "hi") 1)) "nth walks the char seq")
  (is (= (lazy-seq "hi") '(\h \i)) "equality walks the char seq")
  (is (= "(\\h \\i)" (pr-str (lazy-seq "hi"))) "prints as a seq of chars")
  (is (= [\h \i] (into [] (lazy-seq "hi"))) "into")
  (is (= '(104 105) (map int (lazy-seq "hi"))) "map over the char seq")
  (is (= [\a \b] (reduce conj [] (lazy-seq "ab"))) "reduce over the char seq")
  (is (= "ab" (apply str (lazy-seq "ab"))) "apply spreads the char seq")
  (is (= '(0 \a \b) (cons 0 (lazy-seq "ab"))) "cons onto the lazy char seq")
  (is (= '(\a \b 3) (concat (lazy-seq "ab") (lazy-seq [3]))) "concat keeps the -concat2 boundary")
  (is (= '(\a) (take 1 (lazy-seq "ab"))) "take")
  (is (= '(\a \b) (seq (lazy-seq (lazy-seq "ab")))) "nested lazy over a string"))

(deftest empty-bodies-collapse-to-nil
  (is (nil? (seq (lazy-seq nil))) "nil body")
  (is (nil? (seq (lazy-seq []))) "empty vector body")
  (is (nil? (seq (lazy-seq ()))) "empty list body")
  (is (= [nil nil () 0]
         [(seq (lazy-seq "")) (first (lazy-seq "")) (rest (lazy-seq "")) (count (lazy-seq ""))])
      "empty string body: seq nil, first nil, rest (), count 0")
  (is (true? (realized? (doto (lazy-seq ()) seq))) "an empty body still realizes"))

(deftest collection-bodies-seq-like-their-collections
  (is (= [0 '(1 2 3 4) '(1 2 3 4)]
         (let [l (lazy-seq (vec (range 5)))] [(first l) (rest l) (next l)]))
      "vector body: first/rest/next")
  (is (true? (seq? (seq (lazy-seq (vec (range 5)))))) "the realized vector body is a seq")
  (is (= [0 1 2 3 4] (seq (lazy-seq (vec (range 5))))) "sequential equality with the vector")
  (is (= 6 (reduce + (lazy-seq [1 2 3]))) "reduce over a vector body")
  (is (= '(1 2) (doall (lazy-seq [1 2]))) "doall")
  (is (= '(2 3) (seq (lazy-seq (subvec [1 2 3] 1)))) "subvec body")
  (is (= '(0 1 2) (seq (lazy-seq (range 3)))) "range body")
  (is (= '([:a 1]) (seq (lazy-seq {:a 1}))) "map body")
  (is (= '([:a 1] [:b 2]) (seq (lazy-seq (sorted-map :b 2 :a 1)))) "sorted-map body")
  (is (= '(1 2) (sort (seq (lazy-seq #{1 2})))) "set body")
  (is (= '(1 2) (seq (lazy-seq (conj clojure.lang.PersistentQueue/EMPTY 1 2)))) "queue body")
  (is (= '(:a 1) (seq (lazy-seq (first {:a 1})))) "map-entry body seqs as (k v)")
  (is (= '(2 3) (seq (lazy-seq (eduction (map inc) [1 2])))) "eduction body")
  (is (= '(:a) (seq (lazy-seq (.keySet {:a 1})))) "keySet body"))

(deftest host-bodies-are-seqable
  (is (= [1 '(2) 2] (let [l (lazy-seq (to-array [1 2]))] [(first l) (rest l) (count l)]))
      "Java array body")
  (is (= [7 '(8) 2] (let [l (lazy-seq (java.util.ArrayList. [7 8]))] [(first l) (next l) (count l)]))
      "ArrayList body"))

(deftype LazyProbeSeq []
  clojure.lang.ISeq
  (first [_] :f)
  (next [_] nil)
  (more [_] ())
  (cons [_ o] nil)
  (count [_] 1)
  (empty [_] nil)
  (equiv [_ o] false)
  (seq [this] this))

(deftest custom-seqable-and-iseq-bodies-substitute
  (is (= [1 '(2) 2]
         (let [l (lazy-seq (reify clojure.lang.Seqable (seq [_] (list 1 2))))]
           [(first l) (rest l) (count l)]))
      "a Seqable reify is coerced through its -seq")
  (is (= [:f () nil 1]
         (let [l (lazy-seq (LazyProbeSeq.))] [(first l) (rest l) (next l) (count l)]))
      "an ISeq deftype body answers first/rest/next/count through its own methods"))

(deftest nested-lazy-chains-realize-iteratively
  (is (= [1 true 2]
         (let [l (lazy-seq (lazy-seq (lazy-seq [1 2])))] [(first l) (realized? l) (count l)]))
      "three lazy layers collapse to the terminal seq")
  (is (= 100000 (let [l (filter #(= % 100000) (iterate inc 0))] (first l) (first l)))
      "a 100k-deep no-match chain realizes without recursion and re-reads"))

(deftest non-seqable-bodies-raise-on-every-touch
  (testing "scalar / keyword / fn / boolean bodies are not seqable"
    (is (threw? #(first (lazy-seq 1))) "first of a Long body")
    (is (threw? #(seq (lazy-seq 1))) "seq of a Long body")
    (is (threw? #(count (lazy-seq 1))) "count of a Long body")
    (is (threw? #(vec (lazy-seq 1))) "vec of a Long body")
    (is (threw? #(seq (lazy-seq :k))) "keyword body")
    (is (threw? #(seq (lazy-seq inc))) "fn body")
    (is (threw? #(seq (lazy-seq true))) "boolean body"))
  (testing "a failed coercion is not cached (realized? stays false)"
    (let [l (lazy-seq 1)]
      (is (threw? #(first l)) "first touch raises")
      (is (false? (realized? l)) "not realized after the failure")
      ;; AD-067: clj shows an empty seq here (count 0 / seq nil); cljw raises again.
      (is (threw? #(count l)) "second touch raises again (AD)")
      (is (threw? #(seq l)) "third touch raises again (AD)")))
  (testing "a thrown thunk is retried, not cached"
    (let [l (lazy-seq (throw (ex-info "boom" {})))]
      (is (= "boom" (try (first l) (catch Exception e (ex-message e)))) "the body's own exception surfaces")
      (is (false? (realized? l)) "not realized after the throw")
      (is (threw? #(count l)) "the retry raises again"))))

(deftest concurrent-readers-share-one-realization
  (let [calls (atom 0)
        ready (promise)
        body (lazy-seq (swap! calls inc) @ready "hi")
        readers (mapv (fn [_] (future (vec body))) (range 8))]
    (deliver ready true)
    (is (= (vec (repeat 8 [\h \i])) (mapv deref readers)))
    (is (= 1 @calls))
    (is (realized? body))))

(deftest array-sequences-share-their-backing
  (let [array (to-array ["old" "tail"])
        eager (seq array)
        body (lazy-seq array)]
    (is (= "old" (first body)))
    (aset array 0 "new")
    (is (= "new" (first eager)))
    (is (= "new" (first body)))
    (is (= '("tail") (rest body)))))

(deftype InvalidLazySeqable [result]
  clojure.lang.Seqable
  (seq [_] result))

(deftest seqable-results-must-satisfy-iseq
  (doseq [result [[1 2] "hi" 1 {:a 1}]
          invalid [(reify clojure.lang.Seqable (seq [_] result))
                   (InvalidLazySeqable. result)]]
    (is (thrown? ClassCastException (seq invalid))
        "Seqable.seq must return ISeq or nil")
    (is (thrown? ClassCastException (seq (lazy-seq invalid)))
        "lazy coercion enforces the same result contract"))
  (doseq [result [nil () (seq [1 2])]]
    (let [valid (reify clojure.lang.Seqable (seq [_] result))]
      (is (= result (seq valid)))
      (is (= result (seq (lazy-seq valid)))))))

(deftest realization-state-follows-ad067
  (let [calls (atom 0)
        body (lazy-seq (swap! calls inc) (throw (ex-info "retry" {})))]
    (is (= "retry" (try (first body) (catch Exception e (ex-message e)))))
    (is (= "retry" (try (first body) (catch Exception e (ex-message e))))
        "AD-067: retry retains closed-over locals")
    (is (= 2 @calls))
    (is (false? (realized? body))))
  (let [inner (lazy-seq [1 2])
        outer (lazy-seq inner)]
    (is (= '(1 2) (seq outer)))
    (is (realized? inner) "AD-067: each invoked inner node is published")))

(deftest copying-during-realization-keeps-a-valid-payload
  (doseq [_ (range 32)]
    (let [entered (promise)
          ready (promise)
          body (lazy-seq (deliver entered true) @ready "hi")
          reader (future (vec body))]
      @entered
      (let [copiers (mapv (fn [i] (future (vec (with-meta body {:copy i}))))
                          (range 4))]
        (deliver ready true)
        (is (= [\h \i] @reader))
        (is (= (vec (repeat 4 [\h \i])) (mapv deref copiers)))))))
