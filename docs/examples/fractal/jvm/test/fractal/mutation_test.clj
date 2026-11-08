(ns fractal.mutation-test
  "Mutation: the golden views must KILL every plausible mistake in the rules
  everything shares: the orbit (bailout test, iteration limit, count start),
  every formula's step, and the palette. Each mutant is a value fed through
  the same seams the real rules use (the oracle's orbit fn and step table, a
  palette rule map); a mutant the golden views cannot tell apart from the
  real rule is a hole in the golden set.

  Step mutants are not listed by hand: they are derived from the step
  expression (fractal.formula), so a new formula gets its mutants, and needs
  golden views that kill them, the moment it enters the registry."
  (:require [clojure.test :refer [deftest is testing]]
            [fractal.formula :as formula]
            [fractal.golden :as golden]
            [fractal.palette :as palette]
            [fractal.renderer.oracle :as oracle]
            [fractal.tile :as tile]))

;; --- mutants ----------------------------------------------------------------------

(defn- orbit-with
  "An orbit rule with its continue test and count start swapped in."
  [continue? n0]
  (fn [step zr zi cr ci limit]
    (loop [n n0 zr (double zr) zi (double zi)]
      (if (continue? n limit (+ (* zr zr) (* zi zi)))
        (let [[zr' zi'] (step zr zi cr ci)] (recur (inc n) (double zr') (double zi')))
        [n (+ (* zr zr) (* zi zi))]))))

(def orbit-mutants
  {:strict-bailout (orbit-with (fn [n limit m] (and (< n limit) (< m 4.0))) 0)
   :bailout-radius-3 (orbit-with (fn [n limit m] (and (< n limit) (<= m 9.0))) 0)
   :limit-off-by-one (orbit-with (fn [n limit m] (and (<= n limit) (<= m 4.0))) 0)
   :count-from-one (orbit-with (fn [n limit m] (and (< n limit) (<= m 4.0))) 1)})

(defn expr-mutants
  "Every expression one mistake away from e: + and - swapped, an abs dropped,
  a literal negated or off by one, a symbol replaced by another in scope."
  [scope e]
  (cond
    (number? e) [(- e) (+ e 1.0)]
    (symbol? e) (for [s (sort scope) :when (not= s e)] s)
    :else (let [[op & args] e]
            (concat
             (case op + [(apply list '- args)] - [(apply list '+ args)] abs [(first args)] [])
             (for [i (range (count args)) m (expr-mutants scope (nth args i))]
               (apply list op (assoc (vec args) i m)))))))

(defn step-mutants
  "Every step one mistake away from step, in :zr, :zi or a :let expression."
  [{lets :let :as step}]
  (let [scope (into formula/inputs (take-nth 2 lets))]
    (concat
     (for [k [:zr :zi] m (expr-mutants scope (k step))] (assoc step k m))
     (for [i (range 1 (count lets) 2) m (expr-mutants formula/inputs (nth lets i))]
       (assoc-in step [:let i] m)))))

(def palette-mutants
  {:speed-0.026 (assoc palette/rule :speed 0.026)
   :speed-halved (assoc palette/rule :speed 0.0125)
   :channels-swapped (assoc palette/rule :offsets [(/ 1.0 3.0) 0.0 (/ 2.0 3.0)])
   :offsets-quarter (assoc palette/rule :offsets [0.0 0.25 0.5])})

;; --- the judge --------------------------------------------------------------------

(def ^:private views
  "The golden views tests can afford, cheapest first so a kill comes early."
  (delay (sort-by (fn [{:keys [w h iter]}] (* w h iter)) (remove :heavy (golden/load-views)))))

(def ^:private base-steps (delay (oracle/steps)))

(defn- killed?
  "True when a golden view of formula id (every view when id is nil) rejects
  the frames of orbit orb, step table step-of and palette rule pal."
  [id orb step-of pal]
  (boolean
   (some (fn [v]
           (let [t (golden/view->tile v)
                 field (tile/escape-field t)]
             (oracle/fill! orb step-of t field)
             (golden/verdict v (tile/total-iters field) (palette/checksum (palette/paint pal field t)))))
         (cond->> @views id (filter #(= id (:formula (golden/view->tile %))))))))

;; --- the suite --------------------------------------------------------------------

(deftest the-real-rules-survive
  (is (not (killed? nil oracle/orbit @base-steps palette/rule))))

(deftest every-orbit-mutant-is-killed
  (doseq [[k orb] orbit-mutants]
    (testing (name k) (is (killed? nil orb @base-steps palette/rule)))))

(deftest every-step-mutant-is-killed
  (doseq [[id f] formula/registry
          m (step-mutants (:step f))]
    (testing (str id " " (pr-str m))
      (is (killed? id oracle/orbit (assoc @base-steps id (oracle/step-fn (assoc f :step m)))
                   palette/rule)))))

(deftest every-palette-mutant-is-killed
  (doseq [[k pal] palette-mutants]
    (testing (name k) (is (killed? nil oracle/orbit @base-steps pal)))))
