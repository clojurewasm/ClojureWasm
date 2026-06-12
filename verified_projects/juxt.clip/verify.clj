;; juxt/clip — data-driven dependency injection (pure .cljc core).
;; Run by `cljw -M:verify` (-> verify/-main).
(ns verify
  (:require [juxt.clip.core :as clip]))

(defn -main [& _]
  ;; start resolves component order through refs; values are the started comps
  (assert (= {:a 1 :b 1}
             (clip/start {:components {:a {:start 1}
                                       :b {:start (clip/ref :a)}}})))
  ;; :start forms are EVALUATED (code-as-data) with refs spliced in
  (assert (= {:a 1 :b 2}
             (clip/start {:components {:a {:start 1}
                                       :b {:start (list '+ (clip/ref :a) 1)}}})))
  ;; select narrows a system-config to a component subset
  (assert (= {:components {:b {:start 2}}}
             (clip/select {:components {:a {:start 1} :b {:start 2}}} [:b])))
  (println "OK juxt.clip — start with refs / evaluated forms / select"))
