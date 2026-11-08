;; Migrated from test/e2e/phase14_deftype_destructured_param_shadow.sh. Case
;; names and printed expectations are preserved.
;;
;; A defrecord / deftype method parameter that DESTRUCTURES to a name equal to
;; a field must shadow the field, as on the JVM. The lowering wraps each method
;; body in a `let*` that binds the fields; a field bound by the parameter
;; pattern (`{:keys [a]}`, `[a b]`, `{a :k}`, `:as a`) must be left out of that
;; `let*`, or the field silently wins over the argument (found via desargues'
;; RK4 `Pendulum/derivatives [this {:keys [theta omega]}]`).
(ns suites.deftype-destructured-param-shadow-test
  (:require [clojure.test :refer [deftest is]]))

(defprotocol P (f [this m]) (g [this x]) (h [this m]))
(defrecord R [a]
  P
  (f [_ {:keys [a]}] a)
  (g [_ a] a)
  (h [_ m] (let [{:keys [a]} m] a)))

(defprotocol Q (q1 [this v]) (q2 [this m]) (q3 [this m]) (q4 [this m]))
(defrecord S [a b]
  Q
  (q1 [_ [a]] [a b])
  (q2 [_ {a :x}] [a b])
  (q3 [_ {:as a}] [a b])
  (q4 [_ {:keys [c] :or {a 9}}] [a b c]))

(defprotocol D (step [this state dt]))
(deftype Pend [theta omega]
  D
  (step [_ {:keys [theta omega]} dt] [(+ theta dt) (+ omega dt)]))

(deftest defrecord-keys-param-shadows-field
  (let [r (->R :field)]
    (is (= "[:param :param :param]"
           (pr-str [(f r {:a :param}) (g r :param) (h r {:a :param})]))
        "defrecord_keys_param_shadows_field")))

(deftest defrecord-vector-map-as-or-patterns
  (let [s (->S :fa :fb)]
    (is (= "[[:p :fb] [:p :fb] [{:k 1} :fb] [:fa :fb 3]]"
           (pr-str [(q1 s [:p]) (q2 s {:x :p}) (q3 s {:k 1}) (q4 s {:c 3})]))
        "defrecord_vector_map_as_or_patterns")))

(deftest deftype-keys-param-shadows-field
  (is (= "[11 12]" (pr-str (step (->Pend 100 200) {:theta 1 :omega 2} 10)))
      "deftype_keys_param_shadows_field"))
