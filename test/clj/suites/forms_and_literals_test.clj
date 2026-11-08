;; Macros, reader literals, special forms and definition forms (D-158/D-165/
;; D-232/D-273/D-382, ADR-0113/0188, CLJW-UNCHECKED-MATH).
;;
;; Migrated from the phase15 e2e scripts macro_literals, macro_heaplong,
;; literal_roundtrip, reader_conditional, unchecked_math, campaign_keywords
;; (regex-macro + thrown-with-msg?), clojure_template, clojure_uuid,
;; clojure_instant, new_ctor, defmulti_defmethod, defmethod_destructure,
;; marker_protocol, defprotocol_docstring, threaddeath_multifn, with_open,
;; pr_newline and deferred_host_ref (all but its call-time raise, which is an
;; uncatchable not_implemented and stays bash).
;;
;; A macro is only registered once its top-level form completes, so every
;; defmacro-then-call case goes through `ev` (load-string in a fresh scratch
;; ns, the same per-form evaluation `cljw -e` did). *unchecked-math* is a
;; COMPILE-time flag read by the analyzer, so those cases bind it around `ev`.
;; Type / protocol / multimethod names carry a p15 prefix: the suite image is
;; shared.
(ns suites.forms-and-literals-test
  (:require [clojure.test :as t :refer [deftest is testing]]
            [clojure.template]
            [clojure.uuid]
            [clojure.instant]))

(def ^:private scratch-seq (atom 0))

(defn- ev [src]
  (let [n (symbol (str "p15.forms" (swap! scratch-seq inc)))]
    (binding [*ns* (create-ns n)]
      (refer 'clojure.core)
      (load-string src))))

(defn- rd
  "Read `s` the way a .cljc file / `cljw -e` reads it: reader conditionals on."
  [s]
  (read-string {:read-cond :allow} s))

(deftest p15-macro-literals
  (testing "phase15_macro_literals"
    (is (= "1/2" (pr-str (ev "(defmacro m [] `~(/ 1 2)) (m)"))) "ratio")
    (is (= "9999999999800000000001N" (pr-str (ev "(defmacro m [] `~(* 99999999999 99999999999)) (m)"))) "bigint")
    (is (= "3.75M" (pr-str (ev "(defmacro m [] `~(+ 1.50M 2.25M)) (m)"))) "bigdec")
    (is (= "\\b" (pr-str (ev "(defmacro m [] `~(char 98)) (m)"))) "char")
    (is (= "[3/4 123N \\c]" (pr-str (ev "(defmacro m [] `[~(/ 3 4) ~(bigint 123) ~(char 99)]) (m)"))) "mixed")
    (is (= "abc" (ev "(defmacro m [] `(re-find #\"a.c\" \"xabcy\")) (m)")) "regex / campaign regex-macro")))

(def ^:private longify-src
  "(defmacro longify [num] (if (> num Long/MAX_VALUE) (-> num (- 18446744073709551616N) (long) (bit-or -9223372036854775808)) num)) ")

(deftest p15-macro-heaplong
  (testing "phase15_macro_heaplong"
    (is (= "Long" (str (ev (str longify-src "(class (longify 0xbf58476d1ce4e5b9))")))) "longify_returns_long")
    (is (= -4658895280553007687 (ev (str longify-src "(longify 0xbf58476d1ce4e5b9)"))) "longify_value")
    (is (= "Long" (str (binding [*unchecked-math* true]
                         (ev (str longify-src "(class (unsigned-bit-shift-right (* 9223372036854775807 (longify 0xbf58476d1ce4e5b9)) 11))")))))
        "longify_splitmix_compose_no_bigint")
    (is (= "Long" (str (ev "(do (defmacro biglong [] 4658895280553007687) (class (biglong)))"))) "biglong_positive_stays_long")
    (is (= "BigInt" (str (ev "(do (defmacro reallybig [] (* 99999999999999999N 99999999999999999N)) (class (reallybig)))"))) "genuine_bigint_preserved")))

(deftest p15-unchecked-math
  (let [um (fn [src] (binding [*unchecked-math* true] (ev src)))]
    (testing "phase15_unchecked_math: flag off promotes"
      (is (= 18446744073709551614N (ev "(* 9223372036854775807 2)")) "checked_mul_promotes")
      (is (= "BigInt" (str (ev "(class (* 9223372036854775807 2))"))) "checked_mul_class_bigint"))
    (testing "flag on wraps"
      (is (= -2 (um "(* 9223372036854775807 2)")) "unchecked_mul_wraps")
      (is (= "Long" (str (um "(class (* 9223372036854775807 2))"))) "unchecked_mul_class_long")
      (is (= -9223372036854775808 (um "(+ 9223372036854775807 1)")) "unchecked_add_wraps")
      (is (= -9223372036854775808 (um "(inc 9223372036854775807)")) "unchecked_inc_wraps")
      (is (= 9223372036854775807 (um "(dec -9223372036854775808)")) "unchecked_dec_wraps"))
    (testing "arity parity"
      (is (= [10 24 5 -5 0 1] (um "[(+ 1 2 3 4) (* 2 3 4) (- 10 3 2) (- 5) (+) (*)]"))
          "unchecked nary/negate/identity"))
    (testing "n-ary overflow + splitmix shape + value position"
      (is (= "Long" (str (um "(class (* 1000000000000 1000000000 1000000000))"))) "unchecked_nary_wraps")
      (is (= 4503599627370495 (um "(unsigned-bit-shift-right (* 9223372036854775807 7) 11)")) "unchecked_splitmix_shape")
      (is (= "BigInt" (str (um "(class (reduce + [9223372036854775807 2]))"))) "value_position_still_checked"))))

(deftest p15-literal-roundtrip
  (let [mac "(defmacro m [& body] `(do ~@body)) "]
    (testing "phase15_literal_roundtrip: reader literals through a macro"
      (is (= "#uuid \"550e8400-e29b-41d4-a716-446655440000\""
             (pr-str (ev (str mac "(m #uuid \"550e8400-e29b-41d4-a716-446655440000\")")))) "uuid-through-macro")
      (is (true? (ev (str mac "(uuid? (m #uuid \"550e8400-e29b-41d4-a716-446655440000\"))"))) "uuid-through-macro-type")
      (is (true? (ev (str mac "(inst? (m #inst \"2010-11-12T13:14:15.666-05:00\"))"))) "inst-through-macro")
      (is (true? (ev (str mac "(= #inst \"2010-11-12T18:14:15.666-00:00\" (m #inst \"2010-11-12T13:14:15.666-05:00\"))")))
          "inst-round-trip-equal")))
  (testing "resolve follows a require alias"
    (is (= #'clojure.string/blank? (ev "(do (require '[clojure.string :as str]) (resolve 'str/blank?))")) "resolve-through-alias")
    (is (= #'clojure.string/blank? (ev "(do (require '[clojure.string :as str]) (resolve 'clojure.string/blank?))")) "resolve-real-ns-still-works")
    (is (nil? (ev "(do (require '[clojure.string :as str]) (resolve 'str/no-such-var))")) "resolve-alias-miss")
    (is (= #'clojure.string/upper-case
           (ev "(do (require '[clojure.string :as str]) (ns-resolve *ns* 'str/upper-case))")) "ns-resolve-through-alias"))
  (testing "BigDecimal exponents"
    (is (= "1E+5M" (pr-str 1e5M)) "bigdec-positive-exponent")
    (is (= "1E-10M" (pr-str 1E-10M)) "bigdec-negative-exponent")
    (is (= "-1.5E-10M" (pr-str -1.5E-10M)) "bigdec-signed-mantissa-exponent")
    (is (= 150000M 1.5e5M) "bigdec-exponent-value")
    (is (= "123.456M" (pr-str 123.456M)) "bigdec-plain-unchanged"))
  (testing "when-let / when-first with no body"
    (is (nil? (when-let [x 1])) "when-let-empty-body-truthy")
    (is (nil? (when-let [x nil])) "when-let-empty-body-falsey")
    (is (= 10 (when-let [x 5] (* x 2))) "when-let-body-still-runs")
    (is (nil? (when-first [x [1 2]])) "when-first-empty-body")
    (is (= 8 (when-first [x [7 8]] (inc x))) "when-first-body-still-runs")))

(deftest p15-reader-conditional
  (testing "phase15_reader_conditional: feature set {:cljw :clj :default}, left to right"
    (is (= 1 (rd "#?(:clj 1 :cljs 2)")) "clj-branch")
    (is (= 8 (rd "#?(:cljs 9 :clj 8)")) "clj-branch-reordered")
    (is (= 1 (rd "#?(:cljw 1 :clj 2 :cljs 3)")) "cljw-branch")
    (is (= 2 (rd "#?(:clj 2 :cljw 1)")) "cljw-after-clj-loses")
    (is (= 4 (rd "#?(:cljs 9 :cljw 4)")) "cljw-alone")
    (is (= 7 (rd "#?(:cljs 1 :default 7)")) "default-fallback")
    (is (= [1 3] (rd "[1 #?(:cljs 2) 3]")) "no-match-skips")
    (is (= [1] (rd "[1 #?(:cljs 2)]")) "no-match-trailing")
    (is (= '(quote (ns x)) (rd "(quote (ns x #?(:cljs :m)))")) "no-match-ns-tail"))
  (testing "#?@ splicing"
    (is (= [1 2 3 4] (rd "[1 #?@(:clj [2 3]) 4]")) "splice-clj")
    (is (= [1 2 3 4] (rd "[1 #?@(:cljw [2 3] :clj [8 9]) 4]")) "splice-cljw")
    (is (= [0 5] (rd "[0 #?@(:cljs [9]) 5]")) "splice-no-match")
    (is (= '(list 1 2 3) (rd "(list 1 #?@(:clj [2 3]))")) "splice-list")
    (is (thrown-with-msg? Throwable #"only allowed inside" (rd "#?@(:clj [1 2])")) "splice-top-level")))

(deftest p15-thrown-with-msg
  (testing "phase15_campaign_keywords twm-pass / twm-fail"
    (let [run (fn [re]
                (binding [t/*test-out* (java.io.StringWriter.)
                          t/*report-counters* nil
                          t/*testing-vars* (list)
                          t/*testing-contexts* (list)]
                  (let [s (ev (str "(ns p15.twm" (swap! scratch-seq inc) " (:use clojure.test)) "
                                   "(deftest x (is (thrown-with-msg? Throwable #\"" re "\" (throw (ex-info \"boom!\" {}))))) "
                                   "(let [s (run-tests)] [(:pass s) (:fail s)])"))]
                    s)))]
      (is (= [1 0] (run "boom")) "twm-pass")
      (is (= [0 1] (run "nope")) "twm-fail"))))

(deftest p15-bundled-small-nses
  (testing "phase15_clojure_template"
    (is (= '(+ 5 5) (clojure.template/apply-template '[x] '(+ x x) '[5])) "apply-template")
    (is (= 30 (clojure.template/do-template [x y] (+ x y) 1 2 10 20)) "do-template"))
  (testing "phase15_clojure_uuid"
    (is (= #uuid "12345678-1234-1234-1234-123456789abc"
           (clojure.uuid/default-uuid-reader "12345678-1234-1234-1234-123456789abc")))
    (is (= "#uuid \"12345678-1234-1234-1234-123456789abc\""
           (pr-str #uuid "12345678-1234-1234-1234-123456789abc")) "uuid_require_and_reader"))
  (testing "phase15_clojure_instant"
    (is (= #inst "2026-06-10T12:00:00.000-00:00" (clojure.instant/read-instant-date "2026-06-10T12:00:00Z")) "read_instant_date")
    (is (= "java.util.Date" (str (class (clojure.instant/read-instant-date "2026-06-10")))) "read_instant_date class")
    (let [ts (clojure.instant/read-instant-timestamp "2024-01-01T00:00:00.123456789Z")]
      (is (= "[#inst \"2024-01-01T00:00:00.123456789-00:00\" java.sql.Timestamp true 1704067200123 true false]"
             (pr-str [ts (class ts) (inst? ts) (inst-ms ts)
                      (= ts (clojure.instant/read-instant-timestamp "2024-01-01T00:00:00.123456789Z"))
                      (= ts (clojure.instant/read-instant-date "2024-01-01T00:00:00.123Z"))]))
          "read_instant_timestamp"))
    (is (thrown? Exception (clojure.instant/read-instant-date "not-an-instant")) "malformed_throws")
    (is (thrown? Exception (clojure.instant/read-instant-date "2024-01-01T00:00:00\"x")) "quote_chars_rejected")
    (is (thrown? Exception (clojure.instant/read-instant-date "a\\b")) "quote_chars_rejected backslash")))

(deftest p15-new-ctor
  (testing "phase15_new_ctor"
    (is (= "boom" (.getMessage (new Exception "boom"))) "new-exception")
    (is (= ["x" "x"] [(.getMessage (new Exception "x")) (.getMessage (Exception. "x"))]) "new-eq-sugar")
    (is (instance? Exception (new RuntimeException "r")) "new-instance")
    (is (thrown-with-msg? Throwable #"requires a class" (ev "(new)")) "new-no-class")))

(deftest p15-multimethods
  (testing "phase15_defmulti_defmethod"
    (is (= 9 (ev "(do (defmulti area \"the area\" {:arglists (quote ([shape]))} :kind) (defmethod area :square [s] (* (:side s) (:side s))) (area {:kind :square :side 3}))"))
        "defmulti-docstring-dispatch")
    (is (= "the doc" (ev "(do (defmulti m \"the doc\" {:x 1} identity) (:doc (meta (var m))))")) "defmulti-doc-meta")
    (is (= 1 (ev "(do (defmulti m \"d\" {:x 1} identity) (:x (meta (var m))))")) "defmulti-attr-meta")
    (is (nil? (ev "(do (defmulti m identity) (defmethod m :default [_]) (m :anything))")) "defmethod-empty-body"))
  (testing "phase15_defmethod_destructure"
    (is (= 7 (ev "(defmulti foo (fn [x] (:t x))) (defmethod foo :pair [{:keys [a b]}] (+ a b)) (foo {:t :pair :a 3 :b 4})")) "assoc-param")
    (is (= [:x 1 2 '(3 4) [:tag 1 2 3 4]]
           (ev "(defmulti bar (fn [m form] m)) (defmethod bar :x [msg [_ a b & rest :as form]] [msg a b rest form]) (bar :x [:tag 1 2 3 4])"))
        "nested-seq-param")
    (is (= 42 (ev "(defmulti baz class) (defmethod baz Long [n] (* n 2)) (baz 21)")) "symbol-param-regress"))
  (testing "phase15_threaddeath_multifn"
    (is (= 1 (try 1 (catch java.lang.ThreadDeath t (throw t)) (catch Throwable e 3))) "threaddeath_guard_analyses")
    (is (= :ok (try :ok (catch ThreadDeath t :td))) "threaddeath_simple_name")
    (is (true? (ev "(do (defmulti mm identity) (instance? clojure.lang.MultiFn mm))")) "multifn_instance_true")
    (is (false? (instance? clojure.lang.MultiFn +)) "multifn_instance_fn_false")
    (is (false? (instance? clojure.lang.MultiFn 5)) "multifn_instance_scalar_false")
    (is (true? (ev "(do (defmulti mm2 identity) (= (class mm2) clojure.lang.MultiFn))")) "multifn_class_identity")
    (is (true? (ev "(do (defmulti mm3 identity) (isa? (class mm3) clojure.lang.IFn))")) "multifn_isa_ifn")))

(deftest p15-protocols
  (testing "phase15_marker_protocol"
    (is (true? (ev "(defprotocol P15M1 \"marker\") (defrecord P15RM1 [] P15M1) (satisfies? P15M1 (->P15RM1))")) "marker-defrecord")
    (is (true? (ev "(defprotocol P15M2) (defrecord P15RM2 []) (extend-type P15RM2 P15M2) (satisfies? P15M2 (->P15RM2))")) "marker-extend-type")
    (is (false? (ev "(defprotocol P15M3 \"marker\") (defrecord P15Other3 []) (satisfies? P15M3 (->P15Other3))")) "non-member-false")
    (is (= [true 7] (ev "(defprotocol P15G (g [x])) (defrecord P15R4 [n] P15G (g [x] n)) [(satisfies? P15G (->P15R4 1)) (g (->P15R4 7))]")) "method-proto-regress"))
  (testing "phase15_defprotocol_docstring"
    (is (= ["hi ann" "HI bob" true]
           (ev "(defprotocol P15Greet \"a greeting protocol\" (greet [this] \"say hi\") (loud [this] \"SHOUT\")) (defrecord P15Person [nm] P15Greet (greet [this] (str \"hi \" nm)) (loud [this] (str \"HI \" nm))) [(greet (->P15Person \"ann\")) (loud (->P15Person \"bob\")) (satisfies? P15Greet (->P15Person \"x\"))]"))
        "dispatch-with-docstrings")
    (is (false? (ev "(defprotocol P15Hint (^String baz [a] [a b] \"multi-arity, hinted\")) (satisfies? P15Hint 1)")) "hinted-multi-arity")
    (is (false? (ev "(defprotocol P15Doc \"marker only\") (satisfies? P15Doc 1)")) "marker-docstring-only")
    (is (= ["<7>" true]
           (ev "(defprotocol P15Sz :extend-via-metadata true (sz [this] \"render\")) (defrecord P15Lit [v] P15Sz (sz [this] (str \"<\" v \">\"))) [(sz (->P15Lit 7)) (satisfies? P15Sz (->P15Lit 1))]"))
        "option-pair-extend-via-metadata")))

(deftest p15-with-open
  (let [res "(def log (atom [])) (defprotocol P15PC (close [this])) (deftype P15Res [id] P15PC (close [this] (swap! log conj id))) "]
    (testing "phase15_with_open"
      (is (= [:body 2 1] (ev (str res "(with-open [a (->P15Res 1) b (->P15Res 2)] (swap! log conj :body)) @log"))) "reverse-order")
      (is (= [1] (ev (str res "(try (with-open [a (->P15Res 1)] (throw (ex-info \"boom\" {}))) (catch Throwable e :caught)) @log"))) "close-on-throw")
      (is (= 3 (with-open [] (+ 1 2))) "empty-bindings")
      (is (= :result (ev (str res "(with-open [a (->P15Res 1)] :result)"))) "returns-body"))))

(deftest p15-pr-newline
  (testing "phase15_pr_newline"
    (is (= "\"hi\"" (with-out-str (pr "hi"))) "pr-string-quoted")
    (is (= "hi" (with-out-str (print "hi"))) "print-string-unquoted")
    (is (= ":a" (with-out-str (pr :a))) "pr-keyword")
    (is (= "x\ny" (with-out-str (print "x") (newline) (print "y"))) "newline-line-break")))

(deftest p15-deferred-host-ref
  ;; ADR-0113 / AD-022: an unresolved clojure.lang.* ref defers to call time.
  ;; The call-time raise itself is an uncatchable not_implemented and stays in
  ;; test/e2e/phase15_deferred_host_ref.sh.
  (testing "phase15_deferred_host_ref"
    (is (= :ok (ev "(do (defn f [] (clojure.lang.RT/baseLoader)) :ok)")) "defines_and_loads")
    (is (= :defined (ev "(do (def g (fn [] clojure.lang.Compiler/CHAR_MAP)) :defined)")) "value_position_defines")
    (is (thrown-with-msg? Throwable #"No namespace: 'myalias'" (ev "(myalias/foo 1)")) "typo_stays_loud")))
