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
            [fractal.renderer :as r]))

(deftm escape-rows!
  [counts :- (Array int), mag2 :- (Array double), y0 :- Long, y1 :- Long, w :- Long, h :- Long,
   cx :- Double, cy :- Double, scale :- Double, limit :- Long] :- Long
  (let [hw (/ (double w) 2.0)
        hh (/ (double h) 2.0)]
    (loop [y y0]
      (if (< y y1)
        (let [ci (+ cy (* (- (double y) hh) scale))]
          (loop [x 0]
            (when (< x w)
              (let [cr (+ cx (* (- (double x) hw) scale))
                    p (+ (* y w) x)]
                (loop [n 0 zr 0.0 zi 0.0]
                  (if (and (< n limit) (<= (+ (* zr zr) (* zi zi)) 4.0))
                    (recur (inc n) (+ (- (* zr zr) (* zi zi)) cr) (+ (* (* 2.0 zr) zi) ci))
                    (do (aset counts p (unchecked-int n))
                        (aset mag2 p (+ (* zr zr) (* zi zi))))))
                (recur (inc x)))))
          (recur (inc y)))
        y1))))

(def ^:private row-block 4)

(defn- escape-tile! [threads {:keys [cx cy scale w h iter]} {:keys [counts mag2]}]
  (let [blocks (long (Math/ceil (/ (double h) row-block)))
        work (fn [lo hi]
               (doseq [b (range lo hi)]
                 (let [y0 (* row-block b)]
                   (escape-rows! counts mag2 y0 (min h (+ y0 row-block)) w h cx cy scale iter))))]
    (binding [rt/*par-min-size* 1
              rt/*par-threads* threads]
      (rt/parallel-for! blocks work))))

(defrecord Raster [rid threads]
  r/IRenderer
  (id [_] rid)
  (describe [_] {:parity? true :heavy? (nil? threads)
                 :what (str "raster deftm escape loop, "
                            (if threads (str threads " thread") "all cores"))})
  (escape! [_ t field] (escape-tile! threads t field)))

(defn all-cores [] (->Raster "raster-jvm" nil))
(defn one-thread [] (->Raster "raster-jvm-1t" 1))
