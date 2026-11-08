;; Run from the repository root: zig-out/bin/cljw docs/examples/fractal/bench.clj
;; Every cljw renderer (each wasm kernel on each zwasm runtime, plus plain
;; Clojure) on every golden view; each frame must reproduce golden.edn exactly.
;; Timing covers the render call only.
;;   CLJW_FRACTAL_CI=1   only the :ci views (the e2e gate)
;;   HEAVY=1             also :heavy views, on JIT engines only
;; Pipeline: frames -> verdicts -> table (pure). Boundary: printing, exit code.
(ns fractal.bench)

(def root "docs/examples/fractal")
(load-file (str root "/mandel.clj"))
(load-file (str root "/cljw/tile.clj"))
(load-file (str root "/cljw/renderer.clj"))
(load-file (str root "/cljw/engines.clj"))

(def ci? (= "1" (System/getenv "CLJW_FRACTAL_CI")))
(def heavy? (= "1" (System/getenv "HEAVY")))

(defn golden-views []
  (:views (clojure.edn/read-string (slurp (str root "/golden.edn")))))

(defn selected? [v] (if ci? (:ci v) (or (not (:heavy v)) heavy?)))

(defn runs? [rr v]
  (and (fractal.cljw.renderer/renders? rr v)
       (or (not (:heavy v)) (not (:interp? (fractal.cljw.renderer/describe rr))))))

(defn measure [rr v]
  (let [t (fractal.cljw.tile/tile v)
        {:keys [iters rgba ms]} (fractal.cljw.renderer/frame rr t)
        sum (fractal.cljw.tile/checksum rgba)]
    {:engine (fractal.cljw.renderer/id rr) :view (:name v) :ms ms :iters iters :checksum sum
     :golden? (and (= iters (:iters v)) (= sum (:checksum v)))}))

(defn line [{:keys [engine view ms iters checksum golden?]}]
  (format "frame %-14s %-9s %10.2f ms %9.2f Miter/s  iters %d  checksum %d  %s"
          engine view ms (/ iters (* ms 1000.0)) iters checksum (if golden? "golden" "MISMATCH")))

(defn table [rows]
  (clojure.string/join
   "\n" (concat ["| engine | view | ms | Miter/s |" "|---|---|---:|---:|"]
                (for [{:keys [engine view ms iters]} rows]
                  (format "| %s | %s | %.2f | %.2f |" engine view ms (/ iters (* ms 1000.0)))))))

(def renderers (fractal.cljw.engines/discover root fractal.mandel/render))
(def rows
  (vec (for [v (golden-views) :when (selected? v)
             rr renderers :when (runs? rr v)]
         (let [row (measure rr v)] (println (line row)) row))))

(println)
(println (table rows))
(if (every? :golden? rows)
  (println (str "PASS golden: " (count rows) " frames on " (count renderers)
                " engines reproduce golden.edn"))
  (do (println "FAIL golden:" (pr-str (map (juxt :engine :view) (remove :golden? rows))))
      (System/exit 1)))
