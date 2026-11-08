;; cljw.test — discover clojure.test namespaces on the source path and run them.
;;
;; `cljw -cp test -m cljw.test` is a whole test run: no build step, no external
;; runner, no dependency beyond the binary. Discovery walks the source path for
;; `.clj` / `.cljc` / `.cljw` files, derives each file's namespace from its path
;; (the Clojure file-name convention: `_` in a path segment is `-` in the name),
;; requires it, and runs it through `clojure.test/test-ns`.
;;
;; A namespace that throws while LOADING is counted as one error and named in
;; the report, and the run continues — a suite is worth more when one bad
;; namespace costs one row instead of the whole run.

(ns cljw.test
  (:require [clojure.string :as str]
            [clojure.test :as test]
            [cljw.fs :as fs]))

(def ^:private source-extensions [".clj" ".cljc" ".cljw"])

(defn- source-file? [path]
  (boolean (some (fn [ext] (str/ends-with? path ext)) source-extensions)))

(defn- strip-extension [path]
  (let [i (str/last-index-of path ".")]
    (if i (subs path 0 i) path)))

(defn- files-under
  "Every file below `dir`, depth-first, in sorted order."
  [dir]
  (mapcat (fn [entry]
            (let [p (str dir "/" entry)]
              (if (fs/directory? p) (files-under p) [p])))
          (sort (fs/list-dir dir))))

(defn- path->ns
  "The namespace symbol a source file declares, by convention: the path below
  `root`, extension dropped, `_` → `-`, `/` → `.`."
  [root path]
  (-> (subs path (inc (count root)))
      strip-extension
      (str/replace "_" "-")
      (str/replace "/" ".")
      symbol))

(defn namespaces
  "The test namespaces discovered under `root`, sorted. An absent or non-
  directory root contributes none."
  [root]
  (let [root (str/replace root #"/+$" "")]
    (if (fs/directory? root)
      (->> (files-under root)
           (filter source-file?)
           (map (fn [p] (path->ns root p)))
           sort)
      [])))

(defn- source-path
  "The roots to search when none were named: the source path cljw resolved
  (`java.class.path`), else the conventional `test` directory."
  []
  (let [cp (System/getProperty "java.class.path")]
    (if (str/blank? cp)
      ["test"]
      (str/split cp (re-pattern (System/getProperty "path.separator"))))))

(defn- run-ns
  "Require and run one namespace. Returns its counters map with `:ns` added.
  A namespace that throws while loading ran no assertions at all, so it is
  counted as `:unloadable` rather than as an error — an assertion count that
  includes tests which never ran is a lie about coverage."
  [ns-sym]
  (binding [test/*report-counters* (atom test/*initial-report-counters*)]
    (if-let [e (try (require ns-sym) nil (catch Throwable t t))]
      (do (println)
          (println "ERROR loading" (str ns-sym) "-" (ex-message e))
          (assoc test/*initial-report-counters* :ns ns-sym :unloadable 1))
      (assoc (test/test-ns ns-sym) :ns ns-sym))))

(defn run
  "Run every namespace in `ns-syms`, printing each one's failures as they
  happen and a total at the end. Returns the aggregate summary map (the shape
  `clojure.test/run-tests` returns, plus `:namespaces` and `:unloadable`)."
  [ns-syms]
  (let [results (doall (map run-ns ns-syms))
        total (reduce (fn [acc r]
                        (-> acc
                            (update :test + (:test r 0))
                            (update :pass + (:pass r 0))
                            (update :fail + (:fail r 0))
                            (update :error + (:error r 0))
                            (update :unloadable + (:unloadable r 0))))
                      (assoc test/*initial-report-counters* :unloadable 0)
                      results)]
    (doseq [r results
            :when (pos? (+ (:fail r 0) (:error r 0)))]
      (println (str (:ns r)) "-" (:fail r 0) "failures," (:error r 0) "errors"))
    (println)
    (println (count results) "namespaces,"
             (:test total) "tests,"
             (+ (:pass total) (:fail total) (:error total)) "assertions,"
             (:fail total) "failures,"
             (:error total) "errors,"
             (:unloadable total) "unloadable.")
    (assoc total :namespaces (count results))))

(defn- parse-args [args]
  (loop [args (seq args), roots [], include nil, exclude nil]
    (if-let [a (first args)]
      (condp = a
        "--include" (recur (nnext args) roots (second args) exclude)
        "--exclude" (recur (nnext args) roots include (second args))
        (recur (next args) (conj roots a) include exclude))
      {:roots roots :include include :exclude exclude})))

(defn- selected
  "The discovered namespaces of `roots`, narrowed by the include/exclude
  patterns (each a regex matched against the namespace name)."
  [{:keys [roots include exclude]}]
  (let [roots (if (seq roots) roots (source-path))
        keep? (fn [nm]
                (and (or (nil? include) (re-find (re-pattern include) (str nm)))
                     (or (nil? exclude) (not (re-find (re-pattern exclude) (str nm))))))]
    (->> roots (mapcat namespaces) distinct (filter keep?) sort)))

(defn -main
  "Usage: cljw -cp <path> -m cljw.test [ROOT...] [--include RE] [--exclude RE]

  Runs every clojure.test namespace found under ROOT (default: the source
  path). Exits 0 when the run is clean, 1 otherwise."
  [& args]
  (let [summary (run (selected (parse-args args)))]
    (System/exit (if (and (test/successful? summary)
                          (zero? (:unloadable summary 0)))
                   0 1))))
