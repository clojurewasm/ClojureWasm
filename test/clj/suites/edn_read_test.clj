;; clojure.edn/read parity: expected values measured with clojure -M -e.
(ns suites.edn-read-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.edn :as edn]))

(defn- reader [s]
  (java.io.PushbackReader. (java.io.StringReader. s)))

(deftest successive-forms
  (let [r (reader "1 {:a 2} [3 4] ; comment\n :last")]
    (is (= [1 {:a 2} [3 4] :last :done]
           [(edn/read r) (edn/read r) (edn/read r) (edn/read r)
            (edn/read {:eof :done} r)]))))

(deftest eof-options
  (is (= :stop (edn/read {:eof :stop} (reader " ; only comment"))))
  (is (nil? (edn/read {:eof nil} (reader ""))))
  (is (thrown? Exception (edn/read (reader ""))))
  (is (thrown? Exception (edn/read {} (reader "#_42"))))
  (is (= [1 2] (with-in-str "[1 2]" (edn/read)))))

(deftest tag-options
  (is (= 10 (edn/read {:readers {'foo (fn [x] (* x 2))}} (reader "#foo 5"))))
  (is (= ['foo 5] (edn/read {:default (fn [tag value] [tag value])}
                               (reader "#foo 5"))))
  (is (thrown? Exception (edn/read (reader "#foo 5")))))
