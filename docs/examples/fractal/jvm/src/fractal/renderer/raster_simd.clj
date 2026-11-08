(ns fractal.renderer.raster-simd
  "Data-parallel escape on raster's SIMD path. raster vectorizes par/map
  bodies (straight-line arithmetic, if as compare+blend) onto
  jdk.incubator.vector lanes, but cannot vectorize a per-pixel exit. So every
  pass steps ALL pixels once and freezes an escaped pixel with a blend;
  `limit` passes later the counts equal the escape loop's. Exact, vectorized,
  and slower than the escape loop: it does w*h*limit steps where the escape
  loop does sum(counts)."
  (:refer-clojure :exclude [aget aset alength])
  (:require [raster.core :refer [deftm]]
            [raster.arrays :refer [aget alength]]
            [raster.par :as par]
            [raster.compiler.pipeline :as pipeline]
            [fractal.renderer :as r]
            [fractal.tile :as tile]))

(deftm step-zr [zr :- (Array double), zi :- (Array double), cr :- (Array double)] :- (Array double)
  (par/map [i (alength zr)]
    (if (<= (+ (* (aget zr i) (aget zr i)) (* (aget zi i) (aget zi i))) 4.0)
      (+ (- (* (aget zr i) (aget zr i)) (* (aget zi i) (aget zi i))) (aget cr i))
      (aget zr i))))

(deftm step-zi [zr :- (Array double), zi :- (Array double), ci :- (Array double)] :- (Array double)
  (par/map [i (alength zr)]
    (if (<= (+ (* (aget zr i) (aget zr i)) (* (aget zi i) (aget zi i))) 4.0)
      (+ (* (* 2.0 (aget zr i)) (aget zi i)) (aget ci i))
      (aget zi i))))

(deftm step-n [zr :- (Array double), zi :- (Array double), n :- (Array double)] :- (Array double)
  (par/map [i (alength zr)]
    (if (<= (+ (* (aget zr i) (aget zr i)) (* (aget zi i) (aget zi i))) 4.0)
      (+ (aget n i) 1.0)
      (aget n i))))

(defn- compile-steps []
  {:zr (pipeline/compile-aot #'step-zr :simd? true)
   :zi (pipeline/compile-aot #'step-zi :simd? true)
   :n (pipeline/compile-aot #'step-n :simd? true)})

(defn- grid
  "The c plane of tile t as two flat arrays."
  [t]
  (let [{:keys [w h]} t
        cr (double-array (tile/pixels t))
        ci (double-array (tile/pixels t))]
    (dotimes [y h]
      (dotimes [x w]
        (let [[a b] (tile/point t x y) p (+ (* y w) x)]
          (clojure.core/aset cr p (double a))
          (clojure.core/aset ci p (double b)))))
    [cr ci]))

(defn- escape-tile! [{fzr :zr fzi :zi fnn :n} t {:keys [^ints counts ^doubles mag2]}]
  (let [size (tile/pixels t)
        [cr ci] (grid t)]
    (loop [s 0 zr (double-array size) zi (double-array size) n (double-array size)]
      (if (< s (:iter t))
        (recur (inc s) (fzr zr zi cr) (fzi zr zi ci) (fnn zr zi n))
        (let [^doubles zr zr ^doubles zi zi ^doubles n n]
          (dotimes [p size]
            (let [a (clojure.core/aget zr p) b (clojure.core/aget zi p)]
              (clojure.core/aset counts p (int (clojure.core/aget n p)))
              (clojure.core/aset mag2 p (+ (* a a) (* b b))))))))))

(defrecord RasterSimd [steps]
  r/IRenderer
  (id [_] "raster-simd")
  (describe [_] {:parity? true :heavy? false :what "raster par/map on Vector API lanes, one pass per iteration"})
  (escape! [_ t field] (escape-tile! steps t field)))

(defn renderer [] (->RasterSimd (compile-steps)))
