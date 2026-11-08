(ns fractal.engines
  "Collect: which renderers this JVM can run. Each adapter namespace is
  required lazily, so a missing native library (no GPU, no CUDA) costs that
  renderer only and is reported as data."
  (:require [fractal.renderer :as r]))

(def constructors
  "[id qualified-constructor] for every known renderer, in display order."
  [["raster-jvm" 'fractal.renderer.raster/all-cores]
   ["raster-jvm-1t" 'fractal.renderer.raster/one-thread]
   ["raster-simd" 'fractal.renderer.raster-simd/renderer]
   ["cuda-f64" 'fractal.renderer.cuda/f64]
   ["cuda-f32" 'fractal.renderer.cuda/f32]
   ["clojure-jvm" 'fractal.renderer.oracle/renderer]])

(defn discover
  "{:renderers [IRenderer ...] :unavailable [{:id :reason} ...]}"
  ([] (discover constructors))
  ([ctors]
   (r/available (for [[rid qsym] ctors]
                  [rid #((requiring-resolve qsym))]))))
