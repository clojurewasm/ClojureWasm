;; harness.suites — where the cljw-native suite tier IS, as data.
;;
;; One definition, two projections: `test/clj/run_suites.clj` runs it as the
;; gate step `test_clj_suites`, and `dev/user.clj` runs it from a warm nREPL.
;; Neither owns the discovery rule, so the two cannot disagree about which
;; files are suites — the failure mode where a suite runs in the REPL and not
;; in the gate (or the reverse) is structurally unavailable.
;;
;; Strata, in order: `files` COLLECTS (the only form that reads the
;; filesystem), `ns-of` / `namespaces` PROMOTE (pure, over values), and
;; `load-all!` is the BOUNDARY (the only form that mutates the runtime by
;; requiring). Callers that want the list without loading anything stop at
;; Promote.
(ns harness.suites
  (:require [clojure.java.io :as io]
            [clojure.string :as str]))

(def dir
  "The one directory a suite must live in to be discovered."
  "test/clj/suites")

(defn files
  "The *_test.clj file names under `dir`, name-sorted for a stable report.
  Empty when the directory is absent."
  []
  (let [d (io/file dir)]
    (if (.isDirectory d)
      (sort (filter #(str/ends-with? % "_test.clj")
                    (map #(.getName %) (.listFiles d))))
      [])))

(defn ns-of
  "foo_bar_test.clj -> suites.foo-bar-test (Clojure's file<->ns munging)."
  [filename]
  (symbol (str "suites." (str/replace (str/replace filename #"\.clj$" "") "_" "-"))))

(defn namespaces
  "The suite namespace symbols, in discovery order. Pure over `files`."
  ([] (namespaces (files)))
  ([filenames] (mapv ns-of filenames)))

(defn select-files
  "Select discovered files by namespace arguments; report every unknown selector.
  With no selectors, preserve the complete discovered suite set."
  [filenames requested]
  (let [wanted (set (map symbol requested))
        available (set (namespaces filenames))]
    {:files (if (empty? wanted)
              filenames
              (filterv #(contains? wanted (ns-of %)) filenames))
     :missing (vec (sort (remove available wanted)))}))

(defn load-all!
  "Require every suite, returning {:ok [ns…] :failed [[file error]…]}.

  Loading continues past a failure on purpose: a suite that cannot load must
  be REPORTED, not allowed to hide the results of the ones that can."
  ([] (load-all! (files)))
  ([filenames]
   (reduce (fn [acc f]
             (let [n (ns-of f)]
               (try (require n)
                    (update acc :ok conj n)
                    (catch Throwable t
                      (update acc :failed conj [f (str t)])))))
           {:ok [] :failed []}
           filenames)))
