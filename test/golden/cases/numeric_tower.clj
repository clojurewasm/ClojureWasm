;; Where an integer stops being an integer, and what the boundary prints as.
(prn (+ 1 2) (- 1 2) (* 3 4) (/ 6 3) (/ 7 2) (quot 7 2) (rem 7 2) (mod -7 2))
(prn (+ 1 2.0) (* 2 0.5) (== 1 1.0) (= 1 1.0))
(prn (inc 9007199254740992) (* 1000000000000 1000000000000))
(prn (Integer/MAX_VALUE) (inc Integer/MAX_VALUE))
(prn (double 1/3) (float? 1.0) (integer? 1) (ratio? 1/3))
