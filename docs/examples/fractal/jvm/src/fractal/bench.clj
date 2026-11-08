(ns fractal.bench
  "Every available JVM renderer on every golden view. Pipeline: measure rows,
  judge them against golden.edn (pure), render a markdown table (pure).
  Boundary: -main prints, and exits 1 on any golden mismatch."
  (:require [clojure.string :as str]
            [fractal.engines :as engines]
            [fractal.golden :as golden]
            [fractal.palette :as palette]
            [fractal.renderer :as r]))

(defn measure
  "Best of `reps` frames of renderer rr on golden view v, after `warm` frames."
  [rr v {:keys [warm reps] :or {warm 2 reps 5}}]
  (let [t (golden/view->tile v)]
    (dotimes [_ warm] (r/frame rr t))
    (let [frames (repeatedly reps #(r/frame rr t))
          best (apply min-key :ms frames)]
      {:engine (r/id rr)
       :parity? (:parity? (r/describe rr))
       :view (:name v)
       :ms (:ms best)
       :paint-ms (:paint-ms best)
       :iters (:iters best)
       :checksum (palette/checksum (:rgba best))
       :mismatch (golden/verdict v (:iters best) (palette/checksum (:rgba best)))})))

(defn runs?
  "Whether renderer rr runs view v: it renders the view's formula and seed,
  and heavy views only on :heavy? renderers."
  [rr v]
  (and (r/renders? rr (golden/view->tile v))
       (or (not (:heavy v)) (boolean (:heavy? (r/describe rr))))))

(defn rows [renderers views opts]
  (vec (for [rr renderers v views :when (runs? rr v)]
         (measure rr v (if (:heavy v) {:warm 1 :reps 3} opts)))))

(defn failures
  "Rows that must match golden and do not."
  [rows]
  (filterv #(and (:parity? %) (:mismatch %)) rows))

(defn table [rows]
  (str/join "\n"
            (concat ["| engine | view | ms | Miter/s | golden |" "|---|---|---:|---:|---|"]
                    (for [{:keys [engine view ms iters parity? mismatch]} rows]
                      (format "| %s | %s | %.2f | %.1f | %s |" engine view ms (/ iters (* ms 1000.0))
                              (cond (not parity?) "n/a (fp32)" mismatch "MISMATCH" :else "ok"))))))

(defn -main [& _]
  (let [{:keys [renderers unavailable]} (engines/discover)
        rs (rows renderers (golden/load-views) {})
        bad (failures rs)]
    (println "java" (System/getProperty "java.version")
             " cores" (.availableProcessors (Runtime/getRuntime)))
    (doseq [{:keys [id reason]} unavailable] (println "unavailable:" id "-" reason))
    (println (table rs))
    (if (seq bad)
      (do (println "FAIL golden:" (pr-str (map (juxt :engine :view :mismatch) bad))) (shutdown-agents) (System/exit 1))
      (do (println "PASS: every exact engine reproduces golden.edn") (shutdown-agents) (System/exit 0)))))
