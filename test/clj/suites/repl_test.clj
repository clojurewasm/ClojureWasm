;; clojure.repl parity (F-011).
(ns suites.repl-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.repl :as repl]))

;; --- demunge ---
;; demunge maps every `$` (the JVM nested-class separator) to `/`, on top of
;; reversing the munge char tokens. cljw reversed the tokens but left `$`
;; in place, found while writing the dev tooling in cljw.
(deftest demunge-maps-dollar-to-slash
  (testing "the class$fn separator becomes ns/fn"
    (is (= "clojure.core/map" (repl/demunge "clojure.core$map"))))
  (testing "every $ maps to / (nested classes)"
    (is (= "a/b/c" (repl/demunge "a$b$c"))))
  (testing "$ maps alongside the munge tokens"
    (is (= "foo/fn?" (repl/demunge "foo$fn_QMARK_")))
    (is (= "//x" (repl/demunge "_SLASH_$x"))))
  (testing "a name with no $ still reverses the munge tokens"
    (is (= "no-dollar" (repl/demunge "no_dollar")))))

;; --- munge (clojure.core, the inverse of demunge) ---
;; Escapes every character illegal in a Java identifier as a `_TOKEN_`,
;; preserving the argument's type (string or symbol).
(deftest munge-escapes-special-chars
  (testing "string in, string out"
    (is (= "foo_bar_QMARK_" (munge "foo-bar?")))
    (is (= "a_SLASH_b.c_d" (munge "a/b.c-d")))
    (is (= "a_AMPERSAND_b_BAR_c" (munge "a&b|c"))))
  (testing "symbol in, symbol out"
    (is (= 'foo_bar_QMARK_ (munge 'foo-bar?)))
    (is (symbol? (munge 'a))))
  (testing "a name needing no escaping is unchanged"
    (is (= "ok" (munge "ok"))))
  (testing "munge then demunge round-trips a hyphenated name"
    (is (= "foo-bar" (repl/demunge (munge "foo-bar"))))))

;; --- stack-element-str (cljw-native frame map input) ---
;; clj takes a JVM StackTraceElement; cljw has only Clojure frames, so it
;; takes a frame map and produces clj's Clojure-frame render string.
(deftest stack-element-str-renders-a-frame
  (testing "a frame map renders as ns/fn (file:line)"
    (is (= "clojure.core/map (core.clj:2743)"
           (repl/stack-element-str {:ns "clojure.core" :fn "map" :file "core.clj" :line 2743}))))
  (testing "a frame with no ns omits the ns/ prefix"
    (is (= "eval1 (NO_SOURCE_FILE:1)"
           (repl/stack-element-str {:fn "eval1" :file "NO_SOURCE_FILE" :line 1})))))

;; --- Zig-primitive docstrings live in the var meta ---
;; `read-csv` / `monitor-enter` / `monitor-exit` are Zig-interned primitives.
;; Their docs used to sit in `Var.doc` / `Var.arglists` string fields that no
;; user-visible reader consulted, so `(doc clojure.data.csv/read-csv)` printed
;; no docstring and the doc-coverage gate listed them as undocumented. The one
;; home of a docstring is `(:doc (meta v))`.
(require 'clojure.data.csv)

(deftest zig-primitive-docs-are-var-meta
  (testing "(meta #'x) carries :doc and :arglists"
    (doseq [v [#'clojure.data.csv/read-csv #'monitor-enter #'monitor-exit]]
      (is (string? (:doc (meta v))) (str v))
      (is (seq (:arglists (meta v))) (str v))))
  (testing "the arglists are data, not a pre-rendered string"
    (is (= '([s] [s & options]) (:arglists (meta #'clojure.data.csv/read-csv))))
    (is (= '([x]) (:arglists (meta #'monitor-enter)))))
  (testing "clojure.repl/doc prints the docstring"
    (let [out (with-out-str (repl/doc clojure.data.csv/read-csv))]
      (is (re-find #"Reads CSV-data from the string s" out))
      (is (re-find #"\(\[s\] \[s & options\]\)" out)))))
