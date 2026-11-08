(ns harness.corpus
  "Corpus parsing and replay domain. No process or socket ownership."
  (:require [clojure.string :as str]))

(defn parse-pairs [text]
  (:pairs
   (reduce
    (fn [{:keys [expr] :as state} line]
      (cond
        (and expr (str/starts-with? line ";;=> "))
        (-> state
            (update :pairs conj {:expr expr :want (subs line 5)})
            (assoc :expr nil))

        (or (str/blank? line) (str/starts-with? line ";"))
        state

        :else
        (assoc state :expr line)))
    {:expr nil :pairs []}
    (str/split-lines text))))

(defn corpus-stem [path]
  (let [name (.getName (java.io.File. (str path)))]
    (subs name 0 (- (count name) 4))))
