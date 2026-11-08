;; Phase 7 row 7.4: the defrecord surface, asserted natively.
;;
;; Migrated from test/e2e/phase7_defrecord.sh, which paid one cljw process per
;; case (31 spawns). Nothing here needs the PROCESS: the three malformed-form
;; cases raise Kind `syntax_error`, which the error catalog documents as
;; CATCHABLE (bad DATA must be handleable by an `(eval ...)` caller), so they
;; are asserted with `thrown?` around a runtime-read form rather than by
;; grepping a subprocess's stderr.
(ns suites.defrecord-test
  (:require [clojure.test :refer [deftest is]]))

(defrecord DPoint [x y])
(deftype Pair [a b])

;; --- ctor + field access ---

(deftest defrecord-ctor-field-access
  (is (= [3 4] [(.x (DPoint. 3 4)) (.y (DPoint. 3 4))])))

;; --- malformed forms raise a catchable syntax_error at macroexpand ---

(defn- eval-str [s] (eval (read-string s)))

(defn- caught-message
  "Return the message of whatever `(eval (read-string s))` throws, or nil."
  [s]
  (try (eval-str s) nil
       (catch Throwable e (ex-message e))))

(deftest defrecord-form-incomplete-diagnostic
  (is (thrown? Throwable (eval-str "(defrecord NoFields)")))
  (is (re-find #"defrecord requires" (str (caught-message "(defrecord NoFields)")))))

(deftest defrecord-name-invalid-diagnostic
  (is (thrown? Throwable (eval-str "(defrecord \"NotASymbol\" [x])")))
  (is (re-find #"defrecord name" (str (caught-message "(defrecord \"NotASymbol\" [x])")))))

(deftest defrecord-fields-not-vector-diagnostic
  (is (thrown? Throwable (eval-str "(defrecord BadFields \"x\")")))
  (is (re-find #"defrecord fields" (str (caught-message "(defrecord BadFields \"x\")")))))

;; --- implicit IPersistentMap routing (cycle 3) ---

(deftest defrecord-get-declared-field
  (is (= 3 (get (DPoint. 3 4) :x))))

(deftest defrecord-get-sum-two-fields
  (let [p (DPoint. 3 4)]
    (is (= 7 (+ (get p :x) (get p :y))))))

(deftest defrecord-get-undeclared-returns-nil
  (is (nil? (get (DPoint. 3 4) :z))))

(deftest defrecord-get-undeclared-default
  (is (= 99 (get (DPoint. 3 4) :z 99))))

(deftest defrecord-count-field-count
  (is (= 2 (count (DPoint. 3 4)))))

;; A deftype is NOT a map: defrecord is the only TypedInstance whose
;; descriptor.kind enables the implicit map routing in getFn.
(deftest deftype-get-no-map-routing-returns-nil
  (is (nil? (get (Pair. 1 2) :a))))

;; --- assoc (cycle 4) ---

(deftest defrecord-assoc-declared-field
  (is (= 99 (get (assoc (DPoint. 3 4) :x 99) :x))))

(deftest defrecord-assoc-preserves-other-field
  (is (= 4 (get (assoc (DPoint. 3 4) :x 99) :y))))

;; A non-declared key is kept in the record's extmap (clj's __extmap), so the
;; assoc succeeds, the value reads back, and record-ness is preserved
;; (D-086 / ADR-0154; full extmap coverage in test/e2e/phase9_record_extmap.sh).
(deftest defrecord-assoc-undeclared-extmap
  (let [p (assoc (DPoint. 3 4) :z 99)]
    (is (= [99 true] [(get p :z) (record? p)]))))

(deftest defrecord-keys-and-vals
  (is (= [2 2] [(count (keys (DPoint. 3 4))) (count (vals (DPoint. 3 4)))])))

;; --- positional factory + inline protocol bodies (cycle 5) ---

(deftest defrecord-arrow-factory
  (is (= 7 (get (->DPoint 7 8) :x))))

(defprotocol IPos (pos-sum [p]))

(defrecord SummableRec [x y]
  IPos
  (pos-sum [this] (+ (get this :x) (get this :y))))

(deftest defrecord-inline-protocol-body
  (is (= 30 (pos-sum (->SummableRec 10 20)))))

;; --- record? (cycle 6) ---

(deftest record-predicate
  (is (= [true false false] [(record? (->DPoint 1 2))
                             (record? (Pair. 1 2))
                             (record? {:a 1})])))

;; --- value equality ---

(defrecord RecA [v])
(defrecord RecB [v])

(deftest defrecord-value-equality
  (is (= [true false] [(= (->DPoint 1 2) (->DPoint 1 2))
                       (= (->DPoint 1 2) (->DPoint 1 3))])))

(deftest defrecord-not-eq-map
  (is (false? (= (->DPoint 1 2) {:x 1 :y 2}))))

(deftest defrecord-distinct-types-unequal
  (is (false? (= (->RecA 1) (->RecB 1)))))

;; Equal records hash to the same bucket, so one works as a map key.
(deftest defrecord-as-map-key
  (is (= :hit (get {(->DPoint 1 2) :hit} (->DPoint 1 2)))))

;; --- keyword-as-fn ---

(deftest defrecord-keyword-as-fn
  (is (= [1 nil] [(:x (->DPoint 1 2)) (:missing (->DPoint 1 2))])))

;; Regression for the (:k rec) -> nil defect: a protocol method body's (:side s)
;; must read the field, not return nil (which made (* nil nil) throw).
(defprotocol Shape (area [s]))

(defrecord Sq [side]
  Shape
  (area [s] (* (:side s) (:side s))))

(deftest defrecord-protocol-method-keyword-field
  (is (= 16 (area (->Sq 4)))))

;; --- print form ---

(defrecord Pt [x y])

;; A record prints map-style and ns-QUALIFIED, like clj (D-563(a)). The prefix
;; is the DEFINING namespace (print.zig writes `#{defining_ns}.{fqcn}`
;; verbatim), so it is derived here rather than hard-coded: the bash original
;; asserted `#user.Pt{...}` only because a piped script evaluates in `user`.
(def ^:private pt-repr (str "#" (ns-name *ns*) ".Pt{:x 1, :y 2}"))

(deftest defrecord-print-map-style
  (is (= pt-repr (pr-str (->Pt 1 2)))))

;; (str record) renders the CONTENT form, not clj's Object.toString identity
;; form (`ns.Pt@<hash>`). clj's str of a record is the default Object.toString
;; (FQCN@identity-hash), which is non-reproducible (AD-002 class) and
;; JVM-specific (ADR-0059); cljw gives the readable content form for both str
;; and pr. This locks cljw's content-str behaviour (AD-048).
(deftest defrecord-str-content-form
  (is (= pt-repr (str (->Pt 1 2)))))
