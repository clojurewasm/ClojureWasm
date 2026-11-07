(ns fractal.mutation-test
  "Mutation: the golden views must KILL every plausible mistake in the two
  rules everything shares, the escape rule and the palette. Each mutant is a
  value fed through the same seams the real rules use (an Oracle's escape fn,
  a palette rule map); a mutant the golden views cannot tell apart from the
  real rule is a hole in the golden set."
  (:require [clojure.test :refer [deftest is testing]]
            [fractal.golden :as golden]
            [fractal.palette :as palette]
            [fractal.renderer :as r]
            [fractal.renderer.oracle :as oracle]
            [fractal.tile :as tile]))

(defn- escape-with
  "An escape rule with its continue test, step and count start swapped in."
  [continue? step n0]
  (fn [cr ci limit]
    (loop [n n0 zr 0.0 zi 0.0]
      (if (continue? n limit (+ (* zr zr) (* zi zi)))
        (let [[zr' zi'] (step zr zi cr ci)] (recur (inc n) zr' zi'))
        [n (+ (* zr zr) (* zi zi))]))))

(def ^:private kernel-step
  (fn [zr zi cr ci] [(+ (- (* zr zr) (* zi zi)) cr) (+ (* (* 2.0 zr) zi) ci)]))

(def escape-mutants
  {:strict-bailout (escape-with (fn [n limit m] (and (< n limit) (< m 4.0))) kernel-step 0)
   :bailout-radius-3 (escape-with (fn [n limit m] (and (< n limit) (<= m 9.0))) kernel-step 0)
   :limit-off-by-one (escape-with (fn [n limit m] (and (<= n limit) (<= m 4.0))) kernel-step 0)
   :count-from-one (escape-with (fn [n limit m] (and (< n limit) (<= m 4.0))) kernel-step 1)
   :conjugate-step (escape-with (fn [n limit m] (and (< n limit) (<= m 4.0)))
                                (fn [zr zi cr ci] [(+ (- (* zr zr) (* zi zi)) cr) (- ci (* (* 2.0 zr) zi))]) 0)
   :burning-ship (escape-with (fn [n limit m] (and (< n limit) (<= m 4.0)))
                              (fn [zr zi cr ci] [(+ (- (* zr zr) (* zi zi)) cr) (+ (Math/abs (* 2.0 zr zi)) ci)]) 0)})

(def palette-mutants
  {:speed-0.026 (assoc palette/rule :speed 0.026)
   :speed-halved (assoc palette/rule :speed 0.0125)
   :channels-swapped (assoc palette/rule :offsets [(/ 1.0 3.0) 0.0 (/ 2.0 3.0)])
   :offsets-quarter (assoc palette/rule :offsets [0.0 0.25 0.5])})

(defn- golden-views [] (remove :heavy (golden/load-views)))

(defn- killed?
  "True when at least one golden view rejects the frames produced by escape
  rule esc and palette rule pal."
  [esc pal]
  (boolean
   (some (fn [v]
           (let [t (golden/view->tile v)
                 field (tile/escape-field t)]
             (r/escape! (oracle/->Oracle "mutant" esc) t field)
             (golden/verdict v (tile/total-iters field) (palette/checksum (palette/paint pal field t)))))
         (golden-views))))

(deftest the-real-rules-survive
  (is (not (killed? oracle/escape palette/rule))))

(deftest every-escape-mutant-is-killed
  (doseq [[k esc] escape-mutants]
    (testing (name k) (is (killed? esc palette/rule)))))

(deftest every-palette-mutant-is-killed
  (doseq [[k pal] palette-mutants]
    (testing (name k) (is (killed? oracle/escape pal)))))
