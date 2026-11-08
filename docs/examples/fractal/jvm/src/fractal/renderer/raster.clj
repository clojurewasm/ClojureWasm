(ns fractal.renderer.raster
  "replikativ/raster renderers. The escape loop is one deftm, compiled to
  primitive JVM bytecode; rows are split into blocks across a ForkJoin pool by
  raster's parallel-for!. A per-pixel escape loop has a data-dependent exit,
  which raster does not vectorize, so the lanes renderer lives apart
  (fractal.renderer.raster-simd)."
  (:refer-clojure :exclude [aget aset alength])
  (:require [raster.core :refer [deftm]]
            [raster.arrays :refer [aget aset]]
            [raster.par.runtime :as rt]
            [fractal.renderer :as r]
            [clojure.walk :as walk]
            [fractal.formula :as formula]))

(def seeds
  "Seed -> [cr ci zr0 zi0] as forms over the pixel point (px, py) and k (kr, ki)."
  {:c-plane '[px py 0.0 0.0]
   :z-plane '[kr ki px py]})

(def ^:private kernel-template
  "The escape loop over rows [y0, y1) of a tile, with holes for the seed (CR CI
  ZR0 ZI0) and the formula's step (STEP). One test, one order, every formula."
  '(raster.core/deftm NAME
     [counts :- (Array int), mag2 :- (Array double), y0 :- Long, y1 :- Long, w :- Long, h :- Long,
      cx :- Double, cy :- Double, scale :- Double, limit :- Long, kr :- Double, ki :- Double] :- Long
     (let [hw (/ (double w) 2.0)
           hh (/ (double h) 2.0)]
       (loop [y y0]
         (if (< y y1)
           (let [py (+ cy (* (- (double y) hh) scale))]
             (loop [x 0]
               (when (< x w)
                 (let [px (+ cx (* (- (double x) hw) scale))
                       p (+ (* y w) x)
                       cr CR
                       ci CI]
                   (loop [n 0 zr ZR0 zi ZI0]
                     (if (and (< n limit) (<= (+ (* zr zr) (* zi zi)) 4.0))
                       STEP
                       (do (aset counts p (unchecked-int n))
                           (aset mag2 p (+ (* zr zr) (* zi zi))))))
                   (recur (inc x)))))
             (recur (inc y)))
           y1)))))

(defn kernel-name [formula-id seed] (symbol (str "escape-" formula-id "-" (name seed) "!")))

(defn kernel-form
  "The deftm source of the escape loop for Formula f and seed: pure Promote,
  formula data in, raster source out."
  [f seed]
  (let [[cr ci zr0 zi0] (seeds seed)]
    (walk/postwalk-replace
     {'NAME (kernel-name (:id f) seed) 'CR cr 'CI ci 'ZR0 zr0 'ZI0 zi0
      'STEP (formula/step-form (:step f) '[recur (inc n)])}
     kernel-template)))

(defmacro ^:private defkernels
  "One deftm per formula in the registry and per seed."
  []
  (cons 'do (for [f (vals formula/registry) seed (keys seeds)] (kernel-form f seed))))

(defkernels)

(def kernels
  "[formula-id seed] -> compiled escape loop."
  (into {} (for [id (formula/ids) seed (keys seeds)]
             [[id seed] @(ns-resolve 'fractal.renderer.raster (kernel-name id seed))])))

(def ^:private row-block 4)

(defn- escape-tile! [threads {:keys [cx cy scale w h iter formula julia]} {:keys [counts mag2]}]
  (let [kernel (kernels [formula (if julia :z-plane :c-plane)])
        [kr ki] (or julia [0.0 0.0])
        blocks (long (Math/ceil (/ (double h) row-block)))
        work (fn [lo hi]
               (doseq [b (range lo hi)]
                 (let [y0 (* row-block b)]
                   (kernel counts mag2 y0 (min h (+ y0 row-block)) w h cx cy scale iter kr ki))))]
    (binding [rt/*par-min-size* 1
              rt/*par-threads* threads]
      (rt/parallel-for! blocks work))))

(defrecord Raster [rid threads]
  r/IRenderer
  (id [_] rid)
  (describe [_] {:parity? true :heavy? (nil? threads) :julia? true
                 :formulas (set (map first (keys kernels)))
                 :what (str "raster deftm escape loop, "
                            (if threads (str threads " thread") "all cores"))})
  (escape! [_ t field] (escape-tile! threads t field)))

(defn all-cores [] (->Raster "raster-jvm" nil))
(defn one-thread [] (->Raster "raster-jvm-1t" 1))
