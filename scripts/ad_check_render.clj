;; scripts/ad_check_render.clj
;;
;; Renders accepted-divergence check expressions (.dev/accepted_divergences.yaml,
;; `check.expr`) the same way on BOTH runtimes, so the recorded `clj` and `cljw`
;; renderings are comparable. Run by scripts/check_accepted_divergences.sh:
;;
;;   cljw    scripts/ad_check_render.clj <file>            one process per row
;;   clojure -M scripts/ad_check_render.clj <file> ...     one JVM for all rows
;;
;; Each <file> is `(ns ad-check.<id>)` followed by the row's expr. The rendering
;; is `pr-str` of the value of the last form, or `throws <SimpleName>` of the
;; root cause when evaluation raises. A row whose evaluation kills the process
;; (an uncatchable cljw error) prints no line; the caller renders it `aborts`.
;;
;; Output, one line per file: AD-CHECK<TAB><file><TAB><rendering>
;; The driver must stay portable Clojure: it runs unchanged on both runtimes.
(ns ad-check-render)

(defn- root-cause [e]
  (loop [e e]
    (if-let [c (ex-cause e)] (recur c) e)))

(defn- simple-name [e]
  (re-find #"[^.$]+$" (str (.getName (class e)))))

(defn render [path]
  (try
    (binding [*ns* *ns*]
      (pr-str (load-file path)))
    (catch Throwable e
      (str "throws " (simple-name (root-cause e))))))

(doseq [path *command-line-args*]
  (let [r (render path)]
    (println (str "AD-CHECK\t" path "\t" r))
    (flush)))

;; A row may leave a non-daemon thread behind (a sleeping future); the
;; rendering is already printed, so do not wait for it.
(System/exit 0)
