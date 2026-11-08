;; interpreter-bound: non-tail recursion, integer arithmetic.
(defn fib [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(let [t0 (System/nanoTime) r (fib 30)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
