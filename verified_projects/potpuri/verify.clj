;; metosin/potpuri — "common stuff missing from clojure.core" (pure .cljc).
;; Run by `cljw -M:verify` (-> verify/-main).
(ns verify
  (:require [potpuri.core :as p]))
(defn -main [& _]
  (assert (= {:a {:b 1 :c 2}} (p/deep-merge {:a {:b 1}} {:a {:c 2}})))
  (assert (= {:a 2 :b 3} (p/map-vals inc {:a 1 :b 2})))
  ;; find-first is [coll where]: where can be a pred fn, a map, or a value.
  (assert (= 5 (p/find-first [2 4 5 6] odd?)))
  (assert (= {:id 2 :foo :bar} (p/find-first [{:id 1} {:id 2 :foo :bar}] {:id 2})))
  (println "OK potpuri — deep-merge/map-vals/find-first"))
