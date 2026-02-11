;; Upstream: sci/test/sci/io_test.cljc
;; Upstream lines: 106
;; CLJW markers: 5

(ns sci.io-test
  ;; CLJW: removed sci.core, sci.test-utils, clojure.edn dependencies
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests]]))

;; CLJW: all eval*/sci/* calls converted to direct Clojure code

(deftest with-out-str-test
  (is (= "hello\n" (with-out-str (println "hello")))))

(deftest print-test
  (is (= "hello\n" (with-out-str (println "hello"))))
  (is (= "hello" (with-out-str (print "hello"))))
  (is (= "\"hello\"\n" (with-out-str (prn "hello"))))
  (is (= "\"hello\"" (with-out-str (pr "hello"))))
  (is (= "\n" (with-out-str (newline)))))

(deftest print-length-test
  ;; Works with infinite lazy-seq — formatPrStr respects *print-length*
  (is (str/includes?
       (binding [*print-length* 5] (pr-str (range)))
       "(0 1 2 3 4 ...)"))
  ;; println also works with infinite lazy-seq
  (is (str/includes?
       (binding [*print-length* 3] (with-out-str (println (range))))
       "(0 1 2 ...)")))

(deftest print-level-test
  (is (= "[1 [2 #]]"
         (binding [*print-level* 2] (pr-str [1 [2 [3 [4]]]]))))
  (is (= "{:a #}"
         (binding [*print-level* 1] (pr-str {:a {:b {:c 1}}}))))
  ;; println also respects *print-level*
  (is (str/includes?
       (binding [*print-level* 1] (with-out-str (println [1 [2 [3]]])))
       "[1 #]")))

;; CLJW: print-namespace-maps-test, flush-on-newline-test skipped (require Java proxy)

(deftest print-meta-test
  (is (= "^{:a 1} [1 2 3]"
         (binding [*print-meta* true] (pr-str (with-meta [1 2 3] {:a 1})))))
  (is (= "[1 2 3]"
         (binding [*print-meta* false] (pr-str (with-meta [1 2 3] {:a 1}))))))

(deftest print-readably-test
  (is (= "\"hello\"" (pr-str "hello")))
  (is (= "\"hello\"" (binding [*print-readably* true] (pr-str "hello"))))
  (is (= "hello" (binding [*print-readably* false] (pr-str "hello")))))

(deftest print-dup-test
  (is (= "\"hello\"" (binding [*print-dup* true] (pr-str "hello")))))

;; CLJW-ADD: with-in-str-test — test CW implementation
(deftest with-in-str-test
  (is (= "hello" (with-in-str "hello" (read-line)))))

(run-tests)
