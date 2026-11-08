;; Migrated from test/e2e/phase14_qualified_core_special.sh. Case names and
;; printed expectations are preserved.
;;
;; cljw implements `defmacro`, `binding` and `ns` as analyzer special forms,
;; but on the JVM they are clojure.core MACROS, so code (and macro output) may
;; write them qualified: `(clojure.core/defmacro …)`. Emmy's `sci-macro` does.
;; The qualified head (or one through a clojure.core alias) must reach the
;; same analyzer arm instead of calling the nil-rooted marker Var
;; ("macro Var 'defmacro' root binding is not callable").
(ns suites.qualified-core-special-test
  (:require [clojure.test :refer [deftest is]]))

(clojure.core/defmacro qm [x] `(inc ~x))

(require '[clojure.core :as cc])
(cc/defmacro twice [x] `(* 2 ~x))

(def ^:dynamic *d* 1)

(defmacro mk [] `(defmacro ~'gen [y#] y#))
(mk)

(deftest qualified-defmacro
  (is (= "42" (pr-str (qm 41))) "qualified_defmacro"))

(deftest qualified-defmacro-via-eval
  (is (= ":defined"
         (pr-str (try (eval '(clojure.core/defmacro qm2 [x] x)) :defined
                      (catch Throwable e (str "FAIL " (ex-message e))))))
      "qualified_defmacro_via_eval"))

(deftest aliased-core-defmacro
  (is (= "42" (pr-str (twice 21))) "aliased_core_defmacro"))

(deftest qualified-binding
  (is (= "2" (pr-str (clojure.core/binding [*d* 2] *d*))) "qualified_binding"))

(deftest syntax-quoted-defmacro-in-macro-output
  (is (= "7" (pr-str (gen 7))) "syntax_quoted_defmacro_in_macro_output"))
