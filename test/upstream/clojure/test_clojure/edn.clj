;; Upstream: clojure/test/clojure/test_clojure/edn.clj
;; Upstream lines: 39
;; CLJW markers: 6

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; CLJW: upstream uses clojure.test.generative (defspec) which is not available.
;; Replaced with manual roundtrip tests covering the same ednable/non-ednable types.
(ns clojure.test-clojure.edn
  (:require [clojure.test :refer :all]
            [clojure.edn :as edn]))

;; CLJW: roundtrip helper adapted from upstream (Throwable → Exception)
(defn roundtrip
  "Print an object and read it back as edn. Returns rather than throws
   any exceptions."
  [o]
  (binding [*print-length* nil
            *print-dup* nil
            *print-level* nil]
    (try
      (-> o pr-str edn/read-string)
      (catch Exception t t))))

;; CLJW: replaces defspec types-that-should-roundtrip with manual assertions
(deftest test-ednable-roundtrip
  (are [o] (= o (roundtrip o))
    ;; integers
    0 1 -1 42 -100
    ;; floats
    0.0 1.5 -3.14
    ;; strings
    "" "hello" "hello world" "with \"quotes\""
    ;; keywords
    :a :foo/bar
    ;; symbols
    'a 'foo/bar
    ;; nil and booleans
    nil true false
    ;; vectors
    [] [1 2 3] [1 [2 [3]]]
    ;; lists
    '() '(1 2 3) '(1 (2 (3)))
    ;; maps
    {} {:a 1} {:a {:b 2}}
    ;; sets
    #{} #{1 2 3}
    ;; characters
    \a \space \newline
    ;; nested mixed
    {:a [1 2] :b #{:x :y} :c '(3 4)}))

;; CLJW: replaces defspec types-that-should-not-roundtrip
;; instance? Throwable → map? (our caught exceptions are ex-info maps)
(deftest test-non-ednable-roundtrip
  (is (map? (roundtrip inc)))
  (is (map? (roundtrip (fn [x] x)))))

(deftest test-edn-read-string-basic
  (is (= 42 (edn/read-string "42")))
  (is (= :foo (edn/read-string ":foo")))
  (is (= [1 2 3] (edn/read-string "[1 2 3]")))
  (is (= {:a 1} (edn/read-string "{:a 1}")))
  (is (nil? (edn/read-string "")))
  (is (nil? (edn/read-string nil))))

;; CLJW-ADD: test runner invocation
(run-tests)
