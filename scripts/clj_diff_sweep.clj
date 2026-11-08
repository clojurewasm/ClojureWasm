#!/usr/bin/env bb
(ns clj-diff-sweep
  "Compare value expressions through persistent clj and cljw nREPLs."
  (:require [babashka.fs :as fs]
            [clojure.string :as str]
            [harness.nrepl-eval :as eval]
            [harness.process :as process]))

(defn usage! []
  (binding [*out* *err*]
    (println "usage: bb scripts/clj_diff_sweep.clj <exprs-file|-> [--corpus NAME | --class-corpus Class]"))
  (System/exit 2))

(defn parse-args [args]
  (when (empty? args) (usage!))
  (loop [xs (rest args)
         opts {:source (first args)}]
    (if (empty? xs)
      opts
      (let [[flag value & more] xs]
        (case flag
          "--corpus" (recur more (assoc opts
                                         :corpus value
                                         :corpus-dir "test/diff/clj_corpus"))
          "--class-corpus" (recur more (assoc opts
                                               :corpus value
                                               :corpus-dir "test/diff/class_corpus"))
          (usage!))))))

(defn read-expressions [source]
  (->> (str/split-lines (if (= source "-") (slurp *in*) (slurp source)))
       (remove str/blank?)
       (remove #(str/starts-with? % ";"))
       vec))

(defn append-goldens! [{:keys [corpus corpus-dir]} matches]
  (when (and corpus (seq matches))
    (fs/create-dirs corpus-dir)
    (let [path (fs/path corpus-dir (str corpus ".txt"))
          text (apply str
                      (map (fn [{:keys [expr output]}]
                             (str expr "\n;;=> " output "\n"))
                           matches))]
      (spit (str path) text :append true)
      (println (str "appended " (count matches)
                    " golden pair(s) to " path)))))

(defn sweep! [clj-port cljw-port expressions]
  (let [clj (eval/open-session "127.0.0.1" clj-port)
        cljw (eval/open-session "127.0.0.1" cljw-port)]
    (try
      (reduce
       (fn [{:keys [fails matches] :as result} expr]
         (let [oracle (eval/oracle-line clj expr)
               actual (eval/oracle-line cljw expr)]
           (if (= oracle actual)
             (do
               (println (str "OK   " expr))
               (assoc result :matches (conj matches {:expr expr :output actual})))
             (do
               (println (str "DIFF " expr))
               (println (str "       cljw=[" actual "]"))
               (println (str "        clj=[" oracle "]"))
               (assoc result :fails (inc fails))))))
       {:fails 0 :matches []}
       expressions)
      (finally
        (eval/close-session clj)
        (eval/close-session cljw)))))

(defn run-sweep! [opts]
  (let [expressions (read-expressions (:source opts))
        total (count expressions)]
    (when (zero? total)
      (binding [*out* *err*] (println "no expressions"))
      (System/exit 2))
    (process/ensure-cljw-built!)
    (process/with-server
     (process/start-mainline!)
     (fn [clj-server]
       (process/with-server
        (process/start-cljw!)
        (fn [cljw-server]
          (let [{:keys [fails matches]}
                (sweep! (:port clj-server) (:port cljw-server) expressions)]
            (println "---")
            (println (str (- total fails) "/" total " matched, "
                          fails " diff(s)"))
            (append-goldens! opts matches)
            (if (zero? fails) 0 1))))))))

(defn -main [& args]
  (System/exit (run-sweep! (parse-args args))))

(apply -main *command-line-args*)
