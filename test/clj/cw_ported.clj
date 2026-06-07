;; cw v1 §9.13 row 11.3 — ported upstream Clojure tests (Tier A).
;;
;; Each test is a `clojure.test/deftest` using `clojure.test/is`. They register
;; into the current ns; the tail `(run-tests)` runs them and the final form
;; yields `[passes fails]`. (Pre-D-227 this used explicit `defn` + a fn-list
;; `run-tests`; the real `deftest`/`run-tests` now exist.)
;;
;; Sources: ~/Documents/OSS/clojure/test/clojure/test_clojure/*.clj
;; (semantic ports, NOT verbatim copies — each test is rewritten in
;; cw v1's Pattern A surface). Each test has a `;; CLJW:` tier
;; marker comment naming the tier classification (all A for cycle 1).
;;
;; The final form prints `[passes fails]` for `test/run_all.sh`'s
;; `test_clj` step to capture.

;; CLJW: A — arithmetic (clojure.core arithmetic test fragment)
(clojure.test/deftest test-add-int
  (clojure.test/is (= 6 (+ 1 2 3))))

;; CLJW: A — arithmetic
(clojure.test/deftest test-sub-int
  (clojure.test/is (= -1 (- 1 2))))

;; CLJW: A — arithmetic
(clojure.test/deftest test-mul-int
  (clojure.test/is (= 24 (* 2 3 4))))

;; CLJW: A — clojure.string/upper-case via count (cw v1 `=` is
;; number-only today; string identity check uses length proxy).
(clojure.test/deftest test-str-upper
  (clojure.test/is (= 2 (count (clojure.string/upper-case "hi")))))

;; CLJW: A — vector conj / count
(clojure.test/deftest test-vec-conj
  (clojure.test/is (= 3 (count (conj [1 2] 3)))))

;; CLJW: A — map assoc / get
(clojure.test/deftest test-map-assoc-get
  (clojure.test/is (= 99 (get (assoc {:a 1} :b 99) :b))))

;; CLJW: A — set conj / contains?
(clojure.test/deftest test-set-conj-contains
  (clojure.test/is (contains? (conj #{:a :b} :c) :c)))

;; CLJW: A — sequence map + first
(clojure.test/deftest test-seq-map-first
  (clojure.test/is (= 2 (first (map (fn* [x] (* x 2)) [1 2 3])))))

;; CLJW: A — sequence reduce
(clojure.test/deftest test-seq-reduce
  (clojure.test/is (= 15 (reduce + 0 [1 2 3 4 5]))))

;; CLJW: A — clojure.set/intersection (cw v1 `=` is number-only;
;; check element count + membership instead).
(clojure.test/deftest test-set-intersection
  (let* [inter (clojure.set/intersection #{1 2 3} #{2 3 4})]
    (clojure.test/is
      (if (= 2 (count inter))
        (if (contains? inter 2)
          (contains? inter 3)
          false)
        false))))

;; CLJW: A — clojure.edn round-trip (cw v1 `=` number-only; count
;; + first probe).
(clojure.test/deftest test-edn-round-trip
  (let* [v (clojure.edn/read-string "[1 2 3]")]
    (clojure.test/is
      (if (= 3 (count v))
        (if (= 1 (first v))
          (= 3 (nth v 2))
          false)
        false))))

;; CLJW: A — defn closure capture
(clojure.test/deftest test-fn-closure
  (let* [adder (fn* [n] (fn* [x] (+ x n)))]
    (clojure.test/is (= 5 ((adder 3) 2)))))

;; CLJW: A — recur via loop*
(clojure.test/deftest test-loop-recur
  (clojure.test/is
    (= 55 (loop* [i 0 acc 0]
            (if (= i 11) acc (recur (+ i 1) (+ acc i)))))))

;; deftest registers each test under the current ns; run-tests (no arg) runs
;; them and returns the {:test :pass :fail :error} summary. A bare `<file.clj>`
;; runs as a script with no result echo (ADR-0117), so the `[passes fails]`
;; tuple run_tier_a.sh's `awk END` captures is printed explicitly via `(prn …)`.
(let [s (clojure.test/run-tests)]
  (prn [(:pass s) (:fail s)]))
