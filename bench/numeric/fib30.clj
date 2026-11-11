;; (fib 30): self-recursive call through a var, fixnum arithmetic.
;; CLJW-PERF-NUMERIC-UNBOX probe. Expected output: 832040
(defn fib [n]
  (if (< n 2)
    n
    (+ (fib (- n 1)) (fib (- n 2)))))

(println (fib 30))
