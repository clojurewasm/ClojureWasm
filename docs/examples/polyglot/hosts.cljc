;; One Clojure program, three hosts.
;;
;;   cljw hosts.cljc              ClojureWasm   feature set {:cljw :clj :default}
;;   cljrs run hosts.cljc         clojurust     feature set {:rust ...}
;;   clojure -M hosts.cljc        JVM Clojure   feature set {:clj :default}
;;
;; Only the :host line differs per runtime; the computation is host-free
;; Clojure and prints the same value everywhere.
(ns polyglot.hosts
  (:require [clojure.string :as str]))

(def host #?(:cljw "cljw" :rust "cljrs" :clj "jvm" :default "unknown"))

(defn top-words [n text]
  (->> (re-seq #"[A-Za-z]+" text)
       (map str/lower-case)
       frequencies
       (sort-by (fn [[w c]] [(- c) w]))
       (take n)
       vec))

(def sample "The cat and the hat and the bat sat. And the cat sat.")

(println (pr-str {:host host
                  :top (top-words 3 sample)
                  :ratio (/ 22 8)
                  :big (* 1000000007 1000000009)}))
