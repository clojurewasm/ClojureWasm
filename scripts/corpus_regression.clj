#!/usr/bin/env bb
(ns corpus-regression
  "Replay every clj/class corpus golden through one live cljw nREPL."
  (:require [babashka.fs :as fs]
            [harness.corpus :as corpus]
            [harness.nrepl-eval :as eval]
            [harness.process :as process]))

(def host (or (System/getenv "CLJW_REPL_HOST") "127.0.0.1"))
(def corpus-dirs ["test/diff/clj_corpus" "test/diff/class_corpus"])

(defn corpus-files [stem]
  (->> corpus-dirs
       (mapcat (fn [dir]
                 (if stem
                   (let [path (fs/path dir (str stem ".txt"))]
                     (if (fs/regular-file? path) [path] []))
                   (if (fs/directory? dir)
                     (fs/glob dir "*.txt")
                     []))))
       (sort-by str)
       vec))

(def cli-context-corpora
  #{"thread_bindings"})

(defn evaluate-expr
  "Replay `expr` the way clj_diff_sweep recorded its golden: through the oracle
  form, so an error golden (`<clj-error> Kind`) replays as one."
  [port stem expr]
  (if (contains? cli-context-corpora stem)
    ;; nREPL intentionally installs a dynamic binding frame. This corpus tests
    ;; the clojure.main baseline itself, so only the CLI context is equivalent.
    (process/cljw-eval-line (eval/oracle-code expr))
    (let [conn (eval/open-session host port)]
      (try
        (eval/oracle-line conn expr)
        (finally
          (eval/close-session conn))))))

(defn replay-file [port path]
  (let [stem (corpus/corpus-stem path)]
    (reduce
     (fn [{:keys [total fails drifts]} {:keys [expr want]}]
       (let [got (evaluate-expr port stem expr)
             drift? (not= want got)]
         {:total (inc total)
          :fails (+ fails (if drift? 1 0))
          :drifts (cond-> drifts
                    drift? (conj {:stem stem
                                  :expr expr
                                  :want want
                                  :got got}))}))
     {:total 0 :fails 0 :drifts []}
     (corpus/parse-pairs (slurp (str path))))))

(defn replay-in-fresh-runtime [path]
  (if (contains? cli-context-corpora (corpus/corpus-stem path))
    (replay-file nil path)
    (process/with-server
     (process/start-cljw!)
     (fn [server]
       (replay-file (:port server) path)))))

(defn job-count []
  (let [configured (System/getenv "CORPUS_JOBS")
        detected (.availableProcessors (Runtime/getRuntime))]
    (max 1 (min 8 (if configured (Long/parseLong configured) detected)))))

(defn replay-files [files]
  (mapcat
   (fn [batch]
     (let [workers (mapv #(future (replay-in-fresh-runtime %)) batch)]
       (mapv deref workers)))
   (partition-all (job-count) files)))

(defn print-drift! [{:keys [stem expr want got]}]
  (println (str "DRIFT [" stem "] " expr))
  (println (str "   want=[" want "]"))
  (println (str "    got=[" got "]")))

(defn replay! [stem]
  (let [files (corpus-files stem)]
    (if (empty? files)
      (do
        (println "no corpus files — nothing to check")
        0)
      (let [results (vec (replay-files files))
            _ (doseq [result results
                      drift (:drifts result)]
                (print-drift! drift))
            total (reduce + (map :total results))
            fails (reduce + (map :fails results))]
        (println (str "corpus regression: " (- total fails) "/" total
                      " golden outputs reproduced"))
        (if (zero? fails) 0 1)))))

(defn -main [& args]
  (process/ensure-cljw-built!)
  (System/exit (replay! (first args))))

(apply -main *command-line-args*)
