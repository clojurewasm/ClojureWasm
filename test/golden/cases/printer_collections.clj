;; Collection printing, including nesting, empties, and a map's entry form.
(doseq [v ['() [] {} #{}
           '(1 2 3) [1 2 3] {:a 1 :b 2} #{1 2 3}
           [nil [nil [nil]]]
           {:xs [1 2] :m {:k #{:v}}}
           (range 5)
           (map inc [1 2 3])
           (seq "abc")]]
  (prn v))
