;; Arbitrary-precision and exact-fraction rendering: BigInt, BigDecimal, Ratio.
(prn 1N 0N -1N 170141183460469231731687303715884105728N)
(prn (* 1000000000000000000N 1000000000000000000N))
(prn 1M 1.0M 0.10M -2.50M)
(prn (+ 0.1M 0.2M) (* 1.5M 2M) (bigdec 1) (bigint 1))
(prn 1/2 -1/2 3/4 (/ 6 4) (/ 1 3))
(prn (str 1M) (str 1/2) (str 10N) (pr-str 0.10M))
