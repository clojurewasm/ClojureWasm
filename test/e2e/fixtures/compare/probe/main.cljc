(ns probe.main)

(defn report []
  (println "case-1|")
  (println (str "value " (+ 1 2)))
  (println "PROBE-MAIN-DONE"))

(defn -main [& _]
  (report))
