(ns fractal.main
  "Entry point of the JVM tile server: discover renderers, warm them, serve."
  (:require [fractal.engines :as engines]
            [fractal.http :as http]
            [fractal.renderer :as r]
            [fractal.tile :as tile]))

(def warm-tile (tile/tile {:cx -0.6 :cy 0.0 :scale (/ 3.0 256) :w 256 :h 192 :iter 256}))

(defn -main [& [port]]
  (let [port (if port (Long/parseLong port) 8081)
        {:keys [renderers unavailable]} (engines/discover)
        registry (r/registry renderers)]
    (doseq [rr renderers] (dotimes [_ 2] (r/frame rr warm-tile)))
    (http/start! port registry unavailable)
    (println (str "fractal JVM engines on http://localhost:" port "  " (vec (keys registry))))
    (doseq [{:keys [id reason]} unavailable] (println "unavailable:" id "-" reason))))
