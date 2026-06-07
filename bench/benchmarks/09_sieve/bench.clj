;; Sieve of Eratosthenes using filter
(defn make-list [start end]
  (loop [i end acc (list)]
    (if (< i start)
      acc
      (recur (- i 1) (cons i acc)))))

(defn sieve [limit]
  (loop [candidates (make-list 2 limit)
         primes (list)]
    (if (nil? (seq candidates))
      primes
      (let [p (first candidates)
            rest-c (filter (fn [x] (not= 0 (mod x p))) (rest candidates))]
        (recur rest-c (cons p primes))))))

(println (count (sieve 1000)))
