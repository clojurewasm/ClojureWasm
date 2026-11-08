;; test/e2e/phase14_catch_fqcn_exceptions.sh — catch by FULLY-QUALIFIED exception
;; class name (D-398). clj accepts both `(catch AssertionError e …)` and the FQCN
;; `(catch java.lang.AssertionError e …)`. cljw's FQCN→simple map (host_class.zig
;; FQCN_MAP) was missing 3 names that ARE in the hierarchy ENTRIES table:
;; java.lang.AssertionError (assert throws it), java.lang.ReflectiveOperationException,
;; java.lang.ClassNotFoundException — so the FQCN form raised "not a known exception
;; type". Surfaced by clojure.tools.trace (extend-type java.lang.AssertionError). Layer 2.

;; Migrated from test/e2e/phase14_catch_fqcn_exceptions.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.catch-fqcn-exceptions-test
  (:require [clojure.test :refer [deftest is]]))

(deftest catch-fqcn-exceptions-cases
  (is (= ":caught" (pr-str (try (assert false) (catch java.lang.AssertionError e :caught)))) "fqcn-assertion-error")
  (is (= ":caught" (pr-str (try (assert false) (catch AssertionError e :caught)))) "simple-assertion-error")
  (is (= ":caught" (pr-str (try (assert false) (catch java.lang.Error e :caught)))) "fqcn-error-super")
  (is (= ":other" (pr-str (try (throw (ex-info "x" {})) (catch java.lang.ClassNotFoundException e :cnfe) (catch Throwable e :other)))) "fqcn-cnfe")
  (is (= :other (try (throw (ex-info "x" {})) (catch java.lang.NoSuchMethodException _ :nsme) (catch Throwable _ :other))) "fqcn-nsme")
  (is (= :ex (try (throw (Exception. "x")) (catch NoSuchMethodException _ :nsme) (catch Exception _ :ex))) "simple-nsme"))
