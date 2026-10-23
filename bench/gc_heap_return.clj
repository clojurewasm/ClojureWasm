;; CLJW-GC-HEAP-RETURN acceptance probe. A bench, not a test: RSS is
;; host-dependent. Steady-state bursts of one size must not grow the heap
;; after the first, and a major collection must hand freed memory back to
;; the OS. Run: cljw bench/gc_heap_return.clj
(require (quote clojure.data.json) (quote clojure.string))
(defn rss-mb [] (let [l (first (filter #(.startsWith ^String % "VmRSS") (clojure.string/split-lines (slurp "/proc/self/status"))))]
                  (quot (Long/parseLong (re-find #"\d+" l)) 1024)))
(println "start" (rss-mb) "MB")
(def big (atom (vec (range 3000000))))
(println "after 3M vector" (rss-mb) "MB")
(reset! big nil)
(System/gc) (System/gc)
(println "after drop + System/gc" (rss-mb) "MB")
(dotimes [_ 5] (count (vec (range 3000000))))
(println "after 5 more 3M bursts" (rss-mb) "MB")
(dotimes [i 200] (count (clojure.data.json/write-str (vec (range 20000)))))
(System/gc)
(println "after 200 x 20k JSON writes" (rss-mb) "MB")
