;; clojure.data.csv — CSV read/write. Verified loadable on cljw via deps.edn git
;; coords (cljw also bundles it; the git coord documents the upstream source).
;; write-csv is exercised through its primary API — an explicit java.io.Writer —
;; because cljw's `*out*` is a print-sentinel, not a Writer object (the
;; `(.write *out* …)` path is the separate gap D-434, not a data.csv issue).
(ns verify (:require [clojure.data.csv :as csv]))
(defn -main [& _]
  (assert (= [["a" "b"] ["1" "2"]] (csv/read-csv "a,b\n1,2")))
  (assert (= [["x" "y,z"]] (csv/read-csv "x,\"y,z\"")))          ; quoted field with comma
  (assert (= [["a" "b" "c"]] (csv/read-csv "a;b;c" :separator \;)))
  (let [sw (java.io.StringWriter.)]
    (csv/write-csv sw [["a" "b"] ["1" "2"]])
    (assert (= "a,b\n1,2\n" (.toString sw))))
  (let [sw (java.io.StringWriter.)]
    (csv/write-csv sw [["x" "y,z"]])                              ; round-trips the comma-quote
    (assert (= "x,\"y,z\"\n" (.toString sw))))
  (println "OK data.csv — read-csv/write-csv/quoting/:separator (explicit Writer)"))
