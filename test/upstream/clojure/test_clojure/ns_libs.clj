;; Upstream: clojure/test/clojure/test_clojure/ns_libs.clj
;; Upstream lines: 145
;; CLJW markers: 6

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Authors: Frantisek Sodomka, Stuart Halloway

(ns clojure.test-clojure.ns-libs
  (:use clojure.test))

; http://clojure.org/namespaces

; in-ns ns create-ns
; alias import intern refer
; all-ns find-ns
; ns-name ns-aliases ns-imports ns-interns ns-map ns-publics ns-refers
; resolve ns-resolve namespace
; ns-unalias ns-unmap remove-ns

; http://clojure.org/libs

; require use
; loaded-libs

(deftest test-alias
  ;; CLJW: IllegalStateException -> Exception
  (is (thrown-with-msg? Exception #"No namespace: epicfail found" (alias 'bogus 'epicfail))))

(deftest test-require
  (is (thrown? Exception (require :foo)))
  (is (thrown? Exception (require))))

(deftest test-use
  (is (thrown? Exception (use :foo)))
  (is (thrown? Exception (use))))

;; CLJW: JVM interop — reimporting-deftypes (defrecord + import)
;; CLJW: JVM interop — naming-types (definterface, java.lang conflicts)

(deftest resolution
  (let [s (gensym)]
    (are [result expr] (= result expr)
      #'clojure.core/first (ns-resolve 'clojure.core 'first)
      nil (ns-resolve 'clojure.core s)
      nil (ns-resolve 'clojure.core {'first :local-first} 'first)
      nil (ns-resolve 'clojure.core {'first :local-first} s))))

(deftest refer-error-messages
  (let [temp-ns (gensym)]
    (binding [*ns* *ns*]
      (in-ns temp-ns)
      (eval '(def ^{:private true} hidden-var)))
    (testing "referring to something that does not exist"
      ;; CLJW: IllegalAccessError -> Exception
      (is (thrown-with-msg? Exception #"nonexistent-var does not exist"
                            (refer temp-ns :only '(nonexistent-var)))))
    (testing "referring to something non-public"
      ;; CLJW: IllegalAccessError -> Exception
      (is (thrown-with-msg? Exception #"hidden-var is not public"
                            (refer temp-ns :only '(hidden-var)))))))

;; CLJW: JVM interop — test-defrecord-deftype-err-msg (CompilerException)
;; CLJW: require-as-alias, require-as-alias-then-load-later — :as-alias not implemented

(run-tests)
