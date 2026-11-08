(ns fractal.renderer.oracle
  "The reference renderer: the escape-time definition in plain Clojure, one
  pixel at a time, no library. Every other renderer is tested against it."
  (:require [fractal.renderer :as r]
            [fractal.tile :as tile]
            [fractal.formula :as formula]))

(defn orbit
  "[n mag2] for one orbit: iterate z <- (step zr zi cr ci) from z0 while
  n < limit and |z|^2 <= 4. Every kernel uses this test in this order."
  [step zr zi cr ci limit]
  (loop [n 0 zr (double zr) zi (double zi)]
    (if (and (< n limit) (<= (+ (* zr zr) (* zi zi)) 4.0))
      (let [[zr' zi'] (step zr zi cr ci)] (recur (inc n) (double zr') (double zi')))
      [n (+ (* zr zr) (* zi zi))])))

(defn step-fn
  "Compile a Formula's step (data) to a fn of zr zi cr ci returning [zr' zi']."
  [f]
  (eval (list 'fn ['^double zr '^double zi '^double cr '^double ci]
              (formula/step-form (:step f) ['clojure.core/vector]))))

(defn steps
  "Formula id -> compiled step, for every formula in registry."
  ([] (steps formula/registry))
  ([registry] (into {} (map (fn [[id f]] [id (step-fn f)])) registry)))

(defn fill!
  "Fill field for tile t: orbit rule orb, step fn from step-of (formula id ->
  step); returns field. The reference passes `orbit` and `steps`; the
  mutation suite passes deliberately broken ones."
  [orb step-of t {:keys [^ints counts ^doubles mag2] :as field}]
  (let [{:keys [w h iter formula]} t
        step (step-of formula)]
    (dotimes [y h]
      (dotimes [x w]
        (let [[zr zi cr ci] (tile/seed t x y)
              [n m] (orb step zr zi cr ci iter)
              p (+ (* y w) x)]
          (aset counts p (int n))
          (aset mag2 p (double m)))))
    field))

;; esc is the escape rule as a value: the reference passes `escape`, the
;; mutation suite passes deliberately broken rules.
(defrecord Oracle [rid orb step-of]
  r/IRenderer
  (id [_] rid)
  (describe [_] {:parity? true :heavy? false :julia? true :formulas (set (keys step-of))
                 :what "plain Clojure on the JVM, one thread, the reference"})
  (escape! [_ t field] (fill! orb step-of t field)))

(defn renderer [] (->Oracle "clojure-jvm" orbit (steps)))
