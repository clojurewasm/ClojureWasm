;; library: clojure.data.json write-str of a 20k vector plus read-str of a 500-record document.
(require '[clojure.data.json :as json])
(def payload (vec (range 20000)))
(def docs
  (json/write-str
   {:users (vec (map (fn [i] {:id i :name (str "u" i) :tags ["a" "b"] :score (* 1.5 i)}) (range 500)))}))
(defn work [reps]
  (loop [k 0 s 0]
    (if (< k reps)
      (recur (inc k) (+ s (count (json/write-str payload)) (count (get (json/read-str docs) "users"))))
      s)))
(let [t0 (System/nanoTime) r (work 120)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
