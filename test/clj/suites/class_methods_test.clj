;; test/e2e/phase15_class_methods.sh — java.lang.Class instance methods on the
;; `(class x)` value (D-311) + java.util.* collection-interface `instance?`.
;; `(class x)` returns a `.type_descriptor`; its instance methods
;; (.isArray/.getName/.getSimpleName/.isInstance) were unimplemented, and
;; `(instance? java.util.Map x)` raised class_name_unknown. Surfaced by
;; clojure.core.unify's `composite?` (`(-> x class .isArray)` + java.util.Map).
;; Layer 2.

;; Migrated from test/e2e/phase15_class_methods.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.class-methods-test
  (:require [clojure.test :refer [deftest is]]))

(deftest class-methods-cases
  (is (= "false" (pr-str (.isArray (class [1 2])))) "isArray-false")
  (is (= "true" (pr-str (.isArray (class (int-array 3))))) "isArray-true")
  (is (= "\"String\"" (pr-str (.getName (class "x")))) "getName")
  (is (= "\"PersistentVector\"" (pr-str (.getSimpleName (class [1])))) "getSimpleName")
  (is (= "true" (pr-str (.isInstance (class "a") "b"))) "isInstance")
  (is (= "true" (pr-str (instance? java.util.Map {:a 1}))) "util-Map-map")
  (is (= "false" (pr-str (instance? java.util.Map [1]))) "util-Map-vec")
  (is (= "true" (pr-str (instance? java.util.List [1]))) "util-List-vec")
  (is (= "true" (pr-str (instance? java.util.Set #{1}))) "util-Set")
  (is (= "false" (pr-str (instance? java.util.Collection {:a 1}))) "util-Coll-map")
  (is (= "true" (pr-str (instance? java.util.Collection [1]))) "util-Coll-vec"))
