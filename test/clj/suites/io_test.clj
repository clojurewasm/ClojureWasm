;; clojure.core IO-adjacent seq fns (clj parity, F-011).
(ns suites.io-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.java.io :as io]))

;; --- file-seq ---
;; Was missing entirely (`Unable to resolve symbol: 'file-seq'`), found while
;; building the nREPL dev loop, which wanted it to list suite files. Defined the
;; way the JVM does: a tree-seq over .isDirectory / .listFiles.
(deftest file-seq-walks-a-tree
  (testing "a directory yields itself plus its entries"
    (let [names (set (map #(.getName %) (file-seq (io/file "test/clj/suites"))))]
      (is (contains? names "suites"))              ; the root is included
      (is (contains? names "io_test.clj"))
      (is (contains? names "accessors_test.clj"))))
  (testing "a plain FILE yields exactly itself"
    (let [fs (file-seq (io/file "test/clj/suites/io_test.clj"))]
      (is (= 1 (count fs)))
      (is (= "io_test.clj" (.getName (first fs))))))
  (testing "it descends into subdirectories"
    ;; test/clj holds both files and the suites/ subdir, so a correct walk
    ;; reaches names that only exist one level down.
    (let [names (set (map #(.getName %) (file-seq (io/file "test/clj"))))]
      (is (contains? names "suites"))
      (is (contains? names "io_test.clj"))
      (is (contains? names "run_suites.clj")))))

;; --- load-file ---
;; Was missing (`Unable to resolve symbol: 'load-file'`), found building the
;; nREPL dev loop. Defined as clj does: read+eval every form in the file with
;; *file* bound to the path, returning the last form's value.
(deftest load-file-reads-and-evals
  (let [ret (load-file "test/clj/load_fixture.clj")]
    (testing "returns the value of the last form"
      (is (= 84 ret)))
    (testing "defs from the loaded file are interned in the current ns"
      (is (= 42 @(resolve 'load-file-fixture-val)))
      (is (= :loaded @(resolve 'load-file-fixture-marker))))
    (testing "*file* is bound during the load (not the default)"
      (is (some? @(resolve 'load-file-fixture-file))))))

;; --- slurp on a Reader (*in* / with-in-str) ---
;; slurp drains a text_io Reader's unread remainder. The `*in*` / with-in-str
;; reader is a text_io Reader, not a host_stream stream, so it fell through the
;; IOFactory arm and slurp raised "expected string". Found writing dev tooling
;; that did (slurp *in*).
(deftest slurp-drains-a-reader
  (testing "with-in-str: slurp returns the whole string"
    (is (= "hello world" (with-in-str "hello world" (slurp *in*)))))
  (testing "slurp drains only the UNREAD remainder after read-line"
    (is (= "ab|cd\nef" (with-in-str "ab\ncd\nef" (str (read-line) "|" (slurp *in*))))))
  (testing "an empty reader slurps to an empty string"
    (is (= "" (with-in-str "" (slurp *in*))))))
