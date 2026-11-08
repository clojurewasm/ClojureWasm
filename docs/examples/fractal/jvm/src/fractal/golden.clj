(ns fractal.golden
  "The golden views (../golden.edn), shared with the cljw bench: Collect reads
  them, the rest is pure."
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [fractal.tile :as tile]))

(def default-path "../golden.edn")

(defn load-views
  "The golden views; path defaults to ../golden.edn, or FRACTAL_GOLDEN."
  ([] (load-views (or (System/getenv "FRACTAL_GOLDEN") default-path)))
  ([path] (:views (edn/read-string (slurp (io/file path))))))

(defn view->tile [view] (tile/tile view))

(defn verdict
  "Compare a rendered frame with its golden view: nil when equal, else a map
  naming what differs."
  [{:keys [iters checksum name]} frame-iters frame-checksum]
  (when-not (and (= iters frame-iters) (= checksum frame-checksum))
    {:view name
     :expected {:iters iters :checksum checksum}
     :actual {:iters frame-iters :checksum frame-checksum}}))
