;; strings: str, join, split, replace, upper-case, regex scan.
(require '[clojure.string :as str])
(defn work [reps]
  (loop [k 0 s 0]
    (if (< k reps)
      (let [line (str/join "," (map #(str "item-" % "-x") (range 2000)))
            parts (str/split line #",")
            up (str/upper-case line)
            rep (str/replace line "item" "it")
            hits (count (re-seq #"\d+" line))]
        (recur (inc k) (+ s (count parts) (count up) (count rep) hits)))
      s)))
(let [t0 (System/nanoTime) r (work 250)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
