;; [CLJW-MACRO-LITERAL-META]: reader metadata on a collection literal must
;; survive macroexpansion.
;;
;; A macro's return value is a runtime Value, and the analyzer converts it back
;; into a Form (`analyzer.valueToForm`) so it can be re-analyzed. That
;; converter rebuilt a collection from its ELEMENTS only and never read the
;; Value's metadata, so `^:a []` came back stripped. The `.symbol` arm had
;; carried symbol meta across since ADR-0110; collections were missed.
;;
;; The bug is invisible to a direct `cljw -e` or a loaded .clj file, because
;; nothing there round-trips through a macro return. It shows up in exactly one
;; place: inside a macro body. Since every `clojure.test` assertion sits inside
;; `deftest`/`testing`, it made correct functions fail their own upstream suite
;; while passing every hand probe. `clojure.core-test.group-by` reported 6
;; failures whose expressions all pass outside the harness; the function was
;; never at fault.
;;
;; clj preserves the metadata in both positions, so these are parity
;; assertions, not cljw inventions. Checked against Clojure 1.12.4.
(ns suites.macro-literal-meta-test
  (:require [clojure.test :refer [deftest is testing]]))

(defmacro ^:private passthru
  "Returns its body unchanged, forcing a Value->Form round trip."
  [& body]
  `(do ~@body))

;; [CLJW-DEFMACRO-GUARD]: analyzeDefmacro now reads the name's reader meta
;; behind the same `.map` guard analyzeDef uses. Reader meta on a defmacro name
;; (keyword shorthand, tag shorthand, explicit map) still lands on the Var.
(defmacro ^:no-doc ^{:added "t300"} guarded-meta-macro [] 1)

(deftest defmacro-name-meta-guarded
  (is (= 1 (guarded-meta-macro)) "macro still expands")
  (is (true? (:no-doc (meta #'guarded-meta-macro))) "keyword shorthand meta")
  (is (= "t300" (:added (meta #'guarded-meta-macro))) "map meta")
  (is (true? (:macro (meta #'guarded-meta-macro))) "still a macro"))

(defmacro ^:private hand-built
  "Same round trip without syntax-quote, so a failure cannot be blamed on the
   syntax-quote reader."
  [& body]
  (list 'do (cons 'do body)))

(defmacro ^:private inject-meta
  "Metadata the MACRO itself attaches, rather than metadata the reader saw."
  [form]
  (with-meta form {:injected true}))

(deftest vector-literal-meta-survives-macroexpansion
  (testing "the un-macroed form is the control: it always kept its meta"
    (is (= {:a true} (meta ^:a [1]))))
  (is (= {:a true} (meta (passthru ^:a [1]))))
  (is (= {:a true} (meta (hand-built ^:a [1])))))

(deftest map-and-set-literal-meta-survive-macroexpansion
  (is (= {:m true} (meta (passthru ^:m {:k 1}))))
  (is (= {:s true} (meta (passthru ^:s #{1}))))
  (testing "a LIST literal cannot carry a user meta assertion here. `^:l '(1 2)`
            attaches the metadata to the QUOTE form, not to the list, so neither
            runtime sees {:l true}. clj then reports the reader's
            {:line :column} while cljw reports nil, because cljw does not attach
            reader position meta to a quoted form. That difference is unrelated
            to this fix, so assert only the value round trip; the seq arm is
            still exercised, since valueSeqToForm routes through the same
            withValueMeta as the others."
    (is (= '(1 2) (passthru ^:l '(1 2))))))

(deftest nested-literal-meta-survives-macroexpansion
  (testing "metadata on an INNER literal, which is the shape the upstream
            group-by test uses"
    (let [v (passthru [^:inner [1] [2]])]
      (is (= {:inner true} (meta (first v))))
      (is (nil? (meta (second v))))
      (testing "metadata does not leak onto the enclosing collection"
        (is (nil? (meta v)))))))

(deftest meta-injected-by-the-macro-survives
  (testing "not just reader meta: a macro building a form with with-meta must
            see it reach the analyzed value too"
    (is (= {:injected true} (meta (inject-meta [1]))))))

(deftest metadata-does-not-participate-in-equality
  (testing "carrying meta must not change what the collection IS"
    (is (= [1] (passthru ^:a [1])))
    (is (= {:k 1} (passthru ^:m {:k 1})))))

(deftest the-upstream-group-by-shape
  (testing "clojure.core-test.group-by's own assertions, run inside a macro
            body the way deftest runs them"
    (let [g (passthru (group-by first [[^:foo [1] [2]] [^:bar [1] [3]]]))]
      (is (= {[1] [[[1] [2]] [[1] [3]]]} g))
      (is (= {:foo true} (-> g (get [1]) first first meta)))
      (is (= {:bar true} (-> g (get [1]) second first meta))))
    (let [s (passthru (group-by empty? [^:a [] ^:b [1] ^:c [] ^:d [2]]))]
      (is (= {true [[] []] false [[1] [2]]} s))
      (is (= {:a true} (-> s (get true) first meta)))
      (is (= {:c true} (-> s (get true) second meta)))
      (is (= {:b true} (-> s (get false) first meta)))
      (is (= {:d true} (-> s (get false) second meta))))))
