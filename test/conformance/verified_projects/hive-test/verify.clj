;; hive-test — cljw-native execution of its .cljc trifecta core. Both library
;; and test.check are source-pinned because cljw deliberately does not load
;; Maven JARs. Run by `cljw -M:verify` (-> verify/-main).
(ns verify
  (:require [clojure.test :as test]
            [clojure.test.check.generators :as gen]
            [hive-test.trifecta :refer [deftrifecta]]))

(defn magnitude [n]
  (if (neg? n) (- n) n))

(deftrifecta hive-test-on-cljw
  #'verify/magnitude
  {:golden-path "golden.edn"
   :cases {:negative -5 :zero 0 :positive 8}
   :gen (gen/choose -1000 1000)
   :pred #(and (not (neg? %)) (<= % 1000))
   :num-tests 100
   :mutations [["always-zero" (constantly 0)]
               ["identity" identity]]})

(defn -main [& _]
  (let [{:keys [test pass fail error] :as result}
        (test/run-tests 'verify)]
    (assert (= [3 7 0 0] [test pass fail error]) (pr-str result))
    (println "OK hive-test — cljw ran golden/property/mutation trifecta")))
