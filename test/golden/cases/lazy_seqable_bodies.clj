;; [CLJW-LAZY-SEQABLE] — what a lazy-seq body realizes to, printed.
;; Reviewed against clj 1.12.4 on 2026-09-07. AD-067 accounts for the scalar
;; retries, closed-thunk call count and inner realized? state; successful
;; values and first-touch exception classes agree.
(prn (seq (lazy-seq "hi")))
(prn (first (lazy-seq "hi")) (rest (lazy-seq "hi")) (next (lazy-seq "hi")) (count (lazy-seq "hi")))
(prn (lazy-seq "hi"))
(prn (seq (lazy-seq (lazy-seq "ab"))))
(prn (seq (lazy-seq [])) (seq (lazy-seq "")) (rest (lazy-seq "")) (count (lazy-seq "")))
(prn (let [l (lazy-seq (vec (range 5)))] [(first l) (rest l) (next l) (seq? (seq l))]))
(prn (seq (lazy-seq {:a 1})) (seq (lazy-seq (first {:a 1}))) (seq (lazy-seq (sorted-map :b 2 :a 1))))
(prn (let [l (lazy-seq (to-array [1 2]))] [(first l) (rest l) (count l)]))
(prn (let [l (lazy-seq (java.util.ArrayList. [7 8]))] [(first l) (next l) (count l)]))
(prn (let [l (lazy-seq (reify clojure.lang.Seqable (seq [_] (list 1 2))))] [(first l) (rest l) (count l)]))
(deftype GoldenProbeSeq []
  clojure.lang.ISeq
  (first [_] :f)
  (next [_] nil)
  (more [_] ())
  (cons [_ o] nil)
  (count [_] 1)
  (empty [_] nil)
  (equiv [_ o] false)
  (seq [this] this))
(prn (let [l (lazy-seq (GoldenProbeSeq.))] [(first l) (rest l) (next l) (count l)]))
(prn (let [l (lazy-seq (lazy-seq (lazy-seq [1 2])))] [(first l) (realized? l) (count l)]))
(prn (let [l (filter #(= % 100000) (iterate inc 0))] (first l) (first l)))
(let [l (lazy-seq 1)]
  (println "scalar first:" (try (first l) (catch Exception _ :threw)))
  (println "realized after failure:" (realized? l))
  (println "scalar count again:" (try (count l) (catch Exception _ :threw)))
  (println "scalar seq again:" (try (seq l) (catch Exception _ :threw))))
(let [l (lazy-seq (throw (ex-info "boom" {})))]
  (println "thrown thunk:" (try (first l) (catch Exception e (ex-message e))) (realized? l))
  (println "thrown thunk again:" (try (count l) (catch Exception e :threw))))

(prn (let [invalid (reify clojure.lang.Seqable (seq [_] [1 2]))]
       [(try (seq invalid) (catch ClassCastException _ :class-cast))
        (try (seq (lazy-seq invalid)) (catch ClassCastException _ :class-cast))]))

(let [calls (atom 0)
      body (lazy-seq (swap! calls inc) (throw (ex-info "retry" {})))]
  (prn "closed thunk retry:"
       [(try (first body) (catch Exception _ :threw))
        (try (first body) (catch Exception _ :threw))
        @calls (realized? body)]))

(let [inner (lazy-seq [1 2])
      outer (lazy-seq inner)]
  (prn "inner realized:" [(vec outer) (realized? inner)]))
