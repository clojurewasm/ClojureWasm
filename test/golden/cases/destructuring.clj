(let [[a b & rest :as all] [1 2 3 4]
      {:keys [x y] :or {y 99} :as m} {:x 10}]
  (println a b rest all)
  (println x y m))
(defn g [{:keys [k]} & more] [k more])
(prn (g {:k :v} 1 2))
