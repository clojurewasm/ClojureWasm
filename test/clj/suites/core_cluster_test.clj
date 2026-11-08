;; D-126 / D-457 / D-501 / D-502 / D-504: the clojure.core daily-driver cluster
;; that was missing from the bootstrap surface. get-in / assoc-in / update-in /
;; concat / mapcat are Pattern A `.clj` defns over existing primitives; the rest
;; are later gap-fills (namespace-munge, time, flush, future-call, load-string,
;; memfn, xml-seq).
;;
;; Migrated from test/e2e/phase14_core_cluster.sh (29 `cljw -e` spawns). Every
;; case was a value assertion, so the shell is retired entirely.
(ns suites.core-cluster-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.string :as str]))

;; --- get-in ---

(deftest get-in-nested
  (is (= 1 (get-in {:a {:b 1}} [:a :b]))))

(deftest get-in-missing-is-nil
  (is (nil? (get-in {:a 1} [:x :y]))))

(deftest get-in-single-key
  (is (= 7 (get-in {:a 7} [:a]))))

;; The 3-arity not-found sentinel must distinguish an ABSENT key from a key
;; whose value is nil.
(deftest get-in-not-found-sentinel
  (is (= :none (get-in {:a 1} [:x] :none)))
  (is (nil? (get-in {:a nil} [:a] :none))))

;; --- assoc-in ---

(deftest assoc-in-adds-and-preserves
  (let [m (assoc-in {:a {:b 1}} [:a :c] 2)]
    (is (= [2 1] [(get-in m [:a :c]) (get-in m [:a :b])]))))

;; --- update-in ---

(deftest update-in-applies-fn
  (is (= 2 (get-in (update-in {:a {:b 1}} [:a :b] inc) [:a :b]))))

(deftest update-in-passes-extra-args
  (is (= 11 (get-in (update-in {:a {:b 1}} [:a :b] + 10) [:a :b]))))

;; --- concat / mapcat (lazy; realised through `into` so the assertion is
;; order plus content rather than print form) ---

(deftest concat-two-colls
  (is (= [1 2 3 4] (into [] (concat [1 2] [3 4])))))

(deftest concat-three-colls
  (is (= [1 2 3] (into [] (concat [1] [2] [3])))))

(deftest mapcat-single-coll
  (is (= [1 1 2 2 3 3] (into [] (mapcat (fn* [x] [x x]) [1 2 3])))))

(deftest mapcat-two-colls
  (is (= [1 3 2 4] (into [] (mapcat list [1 2] [3 4])))))

(deftest mapcat-three-colls
  (is (= [1 3 5 2 4 6] (into [] (mapcat vector [1 2] [3 4] [5 6])))))

;; Lazy over an INFINITE outer coll: this must not hang.
(deftest mapcat-is-lazy
  (is (= [0 0 1 1 2] (into [] (take 5 (mapcat (fn* [x] [x x]) (range)))))))

;; --- namespace-munge: ns name to a legal package name (- becomes _, . kept) ---

(deftest namespace-munge-hyphen
  (is (= "foo_bar.baz" (namespace-munge "foo-bar.baz"))))

(deftest namespace-munge-symbol
  (is (= "a_b_c" (namespace-munge 'a-b-c))))

(deftest namespace-munge-noop
  (is (= "abc" (namespace-munge "abc"))))

;; --- time: evaluates the expr, prints "Elapsed time: N msecs" through prn (so
;; the string is quoted, matching JVM clj), and returns the expr's value. The
;; msecs number is timing-dependent, so only the framing and the preserved
;; return value are asserted. ---

(deftest time-preserves-return-value
  (let [v (atom nil)]
    (with-out-str (reset! v (time (+ 40 2))))
    (is (= 42 @v))))

(deftest time-prints-elapsed-framing
  (let [out (with-out-str (time 1))]
    (is (str/starts-with? out "\"Elapsed time:"))
    (is (str/includes? out "msecs"))))

;; --- flush: flushes *out* and returns nil ---

(deftest flush-returns-nil
  (is (nil? (flush))))

(deftest flush-on-a-string-sink
  (is (= "ab" (with-out-str (print "ab") (flush)))))

;; --- future-call: the fn behind the future macro. Runs a no-arg thunk
;; off-thread; deref caches the result. ---

(deftest future-call-runs-and-derefs
  (is (= 42 (deref (future-call (fn [] (+ 40 2)))))))

;; --- load-string / memfn / xml-seq ---

;; `lsx` is deliberately an odd name: load-string defs into the GLOBAL
;; environment, which the shell used to isolate by spawning a fresh process per
;; case. In the shared suite image the name has to not collide with anything.
(deftest load-string-evaluates-and-returns-last
  (is (= 15 (load-string "(def lsx-core-cluster 10) (+ lsx-core-cluster 5)"))))

(deftest load-string-empty-is-nil
  (is (nil? (load-string ""))))

;; load-string reads each form only after the previous one ran (the `require`
;; loader), so a `(ns …)` in the string decides how the forms after it read.
;; It used to read the whole string up front and eval one `(do …)`: `::k` and
;; syntax-quote resolved in the CALLER's ns, and a def's computed `^meta`
;; stayed an unevaluated list (so a loaded deftest's `:test` was not callable).
(deftest load-string-reads-each-form-after-the-last-ran
  (let [before (ns-name *ns*)]
    (load-string "(ns ls-cluster-ns) (def k ::here) (def s `here)")
    (testing "a (ns …) in the string governs how its later forms read"
      (is (= :ls-cluster-ns/here @(resolve 'ls-cluster-ns/k)))
      (is (= 'ls-cluster-ns/here @(resolve 'ls-cluster-ns/s))))
    (testing "the caller's ns is restored"
      (is (= before (ns-name *ns*))))))

(deftest load-string-evaluates-def-metadata
  (load-string "(ns ls-cluster-meta) (def ^{:k (+ 1 2)} v 1)")
  (is (= 3 (:k (meta (resolve 'ls-cluster-meta/v))))))

(deftest load-string-deftest-is-runnable
  (load-string "(ns ls-cluster-t (:require [clojure.test :refer [deftest is]])) (deftest t (is (= 1 1)))")
  (is (fn? (:test (meta (resolve 'ls-cluster-t/t))))))

(deftest memfn-zero-arg
  (is (= "HI" ((memfn toUpperCase) "hi"))))

(deftest memfn-two-arg
  (is (= "el" ((memfn substring s e) "hello" 1 3))))

(deftest xml-seq-walks-tree
  (is (= 4 (count (xml-seq {:tag :a :content [{:tag :b :content ["x"]} "y"]})))))
