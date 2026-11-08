;; Throwable-family constructors (D-198 / clj-parity C5, D-425, D-213, D-433).
;;
;; cljw has no JVM class hierarchy (ADR-0059), so each `(X. msg)` mints an
;; `.ex_info` tagged with the class name (the ex-info bridge, ADR-0060);
;; throw/catch, the isSubclassOf hierarchy, instance? and (class e) all ride
;; that tag. Class names are AD-003 simple names, not FQCNs.
;;
;; Migrated from test/e2e/phase14_exception_ctor.sh (one cljw process per
;; assertion). Nothing here touches the CLI surface, so the whole file moves;
;; each assertion keeps its original bash case name as a trailing comment.
(ns suites.exception-ctor-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- constructors + .getMessage ---
(deftest ctor-carries-message
  (is (= "x" (.getMessage (Exception. "x"))))                  ; exc_msg
  (is (= "r" (.getMessage (RuntimeException. "r"))))           ; rte_msg
  (is (= "t" (.getMessage (Throwable. "t")))))                 ; thr_msg

;; --- throw -> catch, by own class / superclass / Throwable ---
(deftest catch-routes-through-the-hierarchy
  (is (= "boom" (try (throw (Exception. "boom"))
                     (catch Exception e (.getMessage e)))))    ; catch_self
  (is (= "r" (try (throw (RuntimeException. "r"))
                  (catch Exception e (.getMessage e)))))       ; catch_super
  (is (= "e" (try (throw (Exception. "e"))
                  (catch Throwable e (.getMessage e))))))      ; catch_thr

(deftest instance?-rides-the-hierarchy
  (is (true? (instance? Exception (Exception. "x"))))          ; inst_exc
  (is (true? (instance? Throwable (RuntimeException. "r"))))   ; inst_thr
  (testing "but not downward"
    (is (false? (instance? RuntimeException (Exception. "x")))))) ; inst_rte

;; --- D-213: (class e) is the value's SPECIFIC exception class, not a
;; generic "ex_info" ---
(deftest class-reports-the-specific-exception-type
  (is (= "ExceptionInfo" (str (class (ex-info "m" {})))))      ; cls_exinfo
  (is (= "Exception" (str (class (Exception. "x")))))          ; cls_exc
  (is (= "RuntimeException" (str (class (RuntimeException. "r"))))) ; cls_rte
  (testing "a caught catalog error carries its Kind-derived class"
    (is (= "ArithmeticException"
           (try (/ 1 0) (catch Throwable e (str (class e))))))  ; cls_div0
    (is (= "IndexOutOfBoundsException"
           (try (nth [] 5) (catch Throwable e (str (class e))))))) ; cls_nth
  (testing "same type interns to one class, distinct types differ"
    (is (true? (= (class (ex-info "a" {})) (class (ex-info "b" {}))))) ; cls_same
    (is (false? (= (class (Exception. "x"))
                   (class (RuntimeException. "y")))))))        ; cls_diff

;; --- D-425: the common java.lang throwable-subtype ctors
;; (the exception_ctors.zig comptime family) ---
(deftest java-lang-subtype-ctors
  (is (= "bad" (.getMessage (IllegalArgumentException. "bad"))))     ; iae_msg
  (is (= "st" (.getMessage (IllegalStateException. "st"))))          ; ise_msg
  (is (= "no" (.getMessage (UnsupportedOperationException. "no"))))  ; uoe_msg
  (is (= "np" (.getMessage (NullPointerException. "np"))))           ; npe_msg
  (is (= "ix" (.getMessage (IndexOutOfBoundsException. "ix"))))      ; ioobe_msg
  (is (= "ar" (.getMessage (ArithmeticException. "ar"))))            ; ae_msg
  (is (= "cc" (.getMessage (ClassCastException. "cc"))))             ; cce_msg
  (is (= "nf" (.getMessage (NumberFormatException. "nf")))))         ; nfe_msg

(deftest subtype-ctors-participate-in-the-hierarchy
  (testing "IllegalArgumentException < RuntimeException < Exception"
    (is (= "x" (try (throw (IllegalArgumentException. "x"))
                    (catch RuntimeException e (.getMessage e)))))    ; iae_as_rte
    (is (= "y" (try (throw (IllegalStateException. "y"))
                    (catch Throwable e (.getMessage e))))))          ; ise_as_thr
  (is (true? (instance? RuntimeException
                        (IllegalArgumentException. "x"))))           ; inst_iae_rte
  (is (= "IllegalArgumentException"
         (str (class (IllegalArgumentException. "x")))))             ; cls_iae
  (testing "(X. msg cause) chains the cause"
    (is (= "in" (.getMessage
                  (.getCause (IllegalArgumentException.
                               "o" (RuntimeException. "in")))))))    ; iae_cause
  )

;; --- D-433: str/.toString give the readable Throwable one-liner
;; `<class>: <message>` (AD-003 simple name; clj prints the FQCN), and a real
;; ex-info appends its data map. pr-str keeps the #error{…} data literal. ---
(deftest str-vs-pr-str-of-an-exception
  (is (= "Exception: boom" (str (Exception. "boom"))))               ; str_exc
  (is (= "Exception: boom" (.toString (Exception. "boom"))))         ; tostr_exc
  (is (= "IllegalArgumentException: x"
         (str (IllegalArgumentException. "x"))))                     ; str_iae
  (is (= "ExceptionInfo: boom {:a 1}" (str (ex-info "boom" {:a 1})))) ; str_exinfo
  (is (= "#error{:message \"boom\" :data {:a 1}}"
         (pr-str (ex-info "boom" {:a 1}))))                          ; prstr_exinfo
  (is (= "#error{:message \"boom\" :data nil}"
         (pr-str (Exception. "boom")))))                             ; prstr_exc
