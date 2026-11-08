;; test/e2e/phase15_class_as_value.sh — host/exception class names as values
;; (D-232). A bare host/exception class symbol (`Exception`, `ExceptionInfo`,
;; `clojure.lang.ExceptionInfo`) now resolves to the same TypeDescriptor value
;; `(class e)` returns, so `(= (class e) SomeException)` works (clj parity) —
;; the analyzer class-as-value path (native classes already worked) is extended
;; to the host_class exception registry via rt.exceptionDescriptor. Surfaced by
;; clojure.test-clojure.fn `(fails-with-cause? clojure.lang.ExceptionInfo …)`.
;; clj-grounded for FQCN / java.lang (corpus class_as_value); the simple
;; clojure.lang name is a cljw leniency (clj needs the FQCN/import). Layer 2.

;; Migrated from test/e2e/phase15_class_as_value.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.class-as-value-test
  (:require [clojure.test :refer [deftest is]]))

(deftest class-as-value-cases
  (is (= "true" (pr-str (= (class (ex-info "x" {})) clojure.lang.ExceptionInfo))) "fqcn-exinfo")
  (is (= "true" (pr-str (= (class (Exception. "y")) Exception))) "java-lang-simple")
  (is (= "false" (pr-str (= (class (Exception. "y")) clojure.lang.ExceptionInfo))) "distinct-classes")
  (is (= "true" (pr-str (= (class (ex-info "x" {})) ExceptionInfo))) "simple-clojure-lang-lenient")
  (is (= "true" (pr-str (class? RuntimeException))) "class-predicate"))
