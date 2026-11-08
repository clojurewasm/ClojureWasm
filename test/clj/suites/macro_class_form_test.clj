;; Migrated from test/e2e/phase14_macro_class_form.sh. Case names and printed
;; expectations are preserved.
;;
;; A macro may return a class OBJECT inside its expansion: `(defmacro m []
;; [String])`, `` `(identity ~clojure.lang.Keyword) ``. On the JVM the class is
;; a constant in the expansion; cljw re-analyses expansions from Forms, so
;; `valueToForm` turns the class back into the class-name symbol that resolves
;; to the same class. Emmy's `defgeneric` (emmy.generic) depends on it. A class
;; with no name that round-trips (a reify) must fail with a precise error.
;;
;; The two cross-namespace cases need code read and evaluated in OTHER
;; namespaces, so they run through `load-string` (which binds `*ns*` around
;; the `ns` switches). Each case gets its own namespace pair so they cannot
;; see each other's types.
(ns suites.macro-class-form-test
  (:require [clojure.test :refer [deftest is]]))

(defmacro m [] [String])
(defmacro k [] `(identity ~clojure.lang.Keyword))
(defmacro classes [] (mapv class [1 1N 1/2 "s" :k 'a [] {} #{} \c 1.0 true]))
(defmacro hm [] {:c java.util.HashMap :e ArithmeticException})
(defmacro s [] `(let [~'String 1] ~String))
(defmacro c [x] (class x))
(defmacro anon [] (class (reify clojure.lang.IDeref (deref [_] 1))))

(deftest vector-of-class
  (is (= "true true" (pr-str (= [String] (m)) (identical? String (first (m)))))
      "vector_of_class"))

(deftest unquoted-class-in-syntax-quote
  (is (= "true true"
         (pr-str (identical? clojure.lang.Keyword (k)) (instance? (k) :a)))
      "unquoted_class_in_syntax_quote"))

(deftest native-value-classes
  (is (= "true"
         (pr-str (= (classes) (mapv class [1 1N 1/2 "s" :k 'a [] {} #{} \c 1.0 true]))))
      "native_value_classes"))

(deftest host-and-exception-classes-in-map
  (is (= "true" (pr-str (= (hm) {:c java.util.HashMap :e ArithmeticException})))
      "host_and_exception_classes_in_map"))

;; A user type from ANOTHER namespace returned by a macro used elsewhere.
(deftest cross-ns-user-types
  (is (= "true true true"
         (load-string
          "(ns suites.mcfcross.types)
           (defrecord Pt [x])
           (deftype Box [v])
           (defmacro pt-class [] Pt)
           (defmacro box-class [] Box)
           (ns suites.mcfcross.user (:require [suites.mcfcross.types :as t]))
           (pr-str (identical? (t/pt-class) suites.mcfcross.types.Pt)
                   (identical? (t/box-class) suites.mcfcross.types.Box)
                   (instance? (t/pt-class) (t/->Pt 1)))"))
      "cross_ns_user_types"))

;; A same-named type in the expanding ns must not capture the class.
(deftest same-name-type-not-captured
  (is (= "true false"
         (load-string
          "(ns suites.mcfcapture.types)
           (defrecord Pt [x])
           (defmacro pt-class [] Pt)
           (ns suites.mcfcapture.user (:require [suites.mcfcapture.types :as t]))
           (defrecord Pt [y])
           (pr-str (identical? (t/pt-class) suites.mcfcapture.types.Pt)
                   (identical? (t/pt-class) Pt))"))
      "same_name_type_not_captured"))

;; A java.lang name shadowed by a local still re-forms to the class.
(deftest local-shadowing-bare-class-name
  (is (= "true" (pr-str (identical? (s) String))) "local_shadowing_bare_class_name"))

(deftest class-through-eval
  (is (= "true true"
         (pr-str (= (c []) clojure.lang.PersistentVector)
                 (identical? (eval `(identity ~Long)) Long)))
      "class_through_eval"))

(deftest anonymous-class-precise-error
  (let [got (try (eval `(anon)) :no-error (catch Throwable e (ex-message e)))]
    (is (string? got) "anonymous_class_precise_error: must throw")
    (is (re-find #"(?s)macro returned class.*cannot be re-analysed" (str got))
        "anonymous_class_precise_error")))
