;; clojure.data.csv — CSV read/write. Verified loadable on cljw via deps.edn git
;; coords (cljw also bundles it; the git coord documents the upstream source).
;; write-csv is exercised both through an explicit java.io.Writer AND through
;; `*out*` (the latter works since D-434 wired Writer-interop on the *out* sentinel).
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
  (assert (= "a,b\n1,2\n"                                          ; D-434: write-csv to *out*
             (with-out-str (csv/write-csv *out* [["a" "b"] ["1" "2"]]))))
  (println "OK data.csv — read-csv/write-csv/quoting/:separator (explicit Writer + *out*)"))
