;; D-207 / clj-parity C3: the universal java.lang.Object instance methods, via
;; a dispatch-level fallback (after a method-table miss) that delegates to the
;; cljw natives: .toString to str, .equals to =, .hashCode to hash, .getClass
;; to class.
;;
;; Accepted divergences carried across from the shell: .hashCode's VALUE is the
;; cljw hash, not the JVM's (AD-009); .getClass prints the simple class name
;; (AD-003); a method call on nil raises where clj NPEs (F-011 covers the
;; format difference).
;;
;; Migrated from test/e2e/phase14_object_methods.sh (24 `cljw -e` spawns). The
;; shell asserted the PRINTED form, so every string case was written as the
;; quoted `"42"` that prn emits; here the value itself is compared. The nil
;; receiver case was a bare "does it exit non-zero" check; the raise is
;; catchable (verified 2026-09-09), so it now asserts the actual message.
(ns suites.object-methods-test
  (:require [clojure.test :refer [deftest is]]))

;; --- .toString delegates to str ---

(deftest to-string-scalars
  (is (= "42" (.toString 42)))
  (is (= ":kw" (.toString :kw)))
  (is (= "hi" (.toString "hi"))))

(deftest to-string-collections
  (is (= "[1 2 3]" (.toString [1 2 3])))
  (is (= "{:a 1}" (.toString {:a 1}))))

;; --- .equals delegates to =, including cross-type sequential equality and
;; the category-gated numeric rule (1 and 1.0 are NOT equal in clj either) ---

(deftest equals-identity-and-numeric-category
  (is (true? (.equals 1 1)))
  (is (false? (.equals 1 1.0))))

(deftest equals-is-sequential-across-types
  (is (true? (.equals [1 2] (list 1 2)))))

(deftest equals-on-sets-ignores-order
  (is (true? (.equals #{1 2} #{2 1}))))

;; --- .hashCode delegates to cljw's hash. The VALUE diverges from the JVM
;; (AD-009), so what is pinned is the delegation and determinism, not a
;; number. ---

(deftest hash-code-delegates-to-hash
  (is (= (hash "abc") (.hashCode "abc"))))

(deftest hash-code-is-an-integer
  (is (integer? (.hashCode 42))))

;; --- .getClass delegates to class, which prints the SIMPLE name (AD-003) ---

(deftest get-class-simple-name
  (is (= "Long" (str (.getClass 42))))
  (is (= "String" (str (.getClass "x")))))

;; --- a nil receiver raises. clj throws NullPointerException; cljw raises its
;; own protocol-dispatch error, and the Kind difference is F-011 territory, so
;; the assertion is on the message's substance rather than an exception class. ---

(deftest nil-receiver-raises
  (is (thrown-with-msg? Throwable #"toString" (.toString nil))))

;; --- D-212: str and .toString of a BigInt / BigDecimal DROP the N / M reader
;; suffix, matching JVM BigInteger/BigDecimal.toString (plain digits), while
;; pr / prn KEEP it so the value still round-trips through the reader. ---

(deftest str-drops-bigint-suffix
  (is (= "100" (str 100N)))
  (is (= "-7" (str -7N))))

(deftest str-drops-bigdec-suffix-and-keeps-scale
  (is (= "1.5" (str 1.5M)))
  (is (= "1.50" (str 1.50M)))
  (is (= "0.001" (str 0.001M))))

(deftest to-string-matches-str-for-bignums
  (is (= "100" (.toString 100N)))
  (is (= "1.5" (.toString 1.5M))))

(deftest pr-str-keeps-the-reader-suffix
  (is (= "100N" (pr-str 100N)))
  (is (= "1.5M" (pr-str 1.5M))))

;; Nested inside a collection, str uses the PRINT form of the elements, so the
;; suffixes come back. This is the case that shows the rule is about the
;; top-level scalar rendering, not about bignums generally.
(deftest str-of-a-collection-keeps-element-suffixes
  (is (= "[100N 1.5M]" (str [100N 1.5M]))))
