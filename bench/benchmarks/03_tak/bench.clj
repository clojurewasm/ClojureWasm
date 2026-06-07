(defn tak [x y z]
  (if (<= x y)
    z
    (tak (tak (- x 1) y z)
         (tak (- y 1) z x)
         (tak (- z 1) x y))))

(println (tak 18 12 6))
