;; Hashing a String that is not valid UTF-8 (CLJW-HASH-INVALID-UTF8).
;;
;; A cljw String is raw BYTES (AD-009), so `(slurp "x.wasm")` is an ordinary
;; value, not abuse. `hash` used to walk it with
;; `std.unicode.Utf8View.initUnchecked`, whose iterator trips `unreachable` on
;; a malformed sequence: a process ABORT, not a catchable Clojure error.
;;
;; READ THIS BEFORE TRUSTING A GREEN RUN. A regression here does not fail an
;; assertion, it kills the runner: the whole suite process dies and there is no
;; report. So "0 failures" from this file means the calls RETURNED, and that is
;; the property being asserted. The value comparisons are secondary, and the
;; decisive evidence for the original fix was differential, one binary against
;; the other, which no in-process suite can produce.
;;
;; The Zig side (`src/runtime/hash.zig`) carries the unit test over the byte
;; patterns; this asserts the guarantee a Clojure caller actually depends on:
;; every String is hashable, therefore every String can be a map key.
(ns suites.hash-invalid-utf8-test
  (:require [clojure.test :refer [deftest is testing]]))

(def ^:private binary-file "test/e2e/fixtures/wasm/resource_counter.wasm")

(deftest hash-is-total-over-a-string-of-arbitrary-bytes
  (let [b (slurp binary-file)]
    (testing "it returns at all, and is deterministic"
      (is (integer? (hash b)))
      (is (= (hash b) (hash (slurp binary-file)))
          "the same bytes hash the same"))

    (testing "so the String can be used where a hash is required"
      (is (= :ok (get {b :ok} (slurp binary-file)))
          "as a map key, looked up by an equal value read separately")
      (is (= 1 (count (conj #{} b (slurp binary-file))))
          "as a set member: two equal readings collapse to one")
      (is (= 2 (count (conj #{} b "plain")))
          "and a different value stays distinct"))

    (testing "equality is still by BYTES, not by the lossy decoding"
      ;; Replacement is per invalid byte, so distinct invalid inputs stay
      ;; distinguishable rather than collapsing to one replacement char.
      ;; Collisions are permitted for a hash; `=` must not collide.
      (is (not= b (str b "x")))
      (is (= b (slurp binary-file))))))

(deftest valid-utf8-is-unaffected
  (testing "ASCII and astral text hash as before the lossy decoder landed"
    (is (= (hash "abc") (hash (str "a" "bc"))))
    (is (= (hash "₻7野家") (hash (str "₻7" "野家"))))
    (is (not= (hash "abc") (hash "abd")))))
