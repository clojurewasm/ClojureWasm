;; Loop-only probe for the VM dispatch floor (CLJW-PERF-RECUR-LOOP).
;; Usage: cljw recur_loop.clj <variant> <n>
;; Count `instructions:u` pinned to one core; subtract the n=0 run for startup.
(def variant (or (first *command-line-args*) "empty"))
(def n (parse-long (or (second *command-line-args*) "600000")))

(defn run [v n]
  (case v
    "empty" (loop [i 0 s 0] (if (< i n) (recur (inc i) (+ s 1)) s))
    "inc"   (loop [i 0] (if (< i n) (recur (inc i)) i))
    "plus"  (loop [i 0] (if (< i n) (recur (+ i 1)) i))
    "two"   (loop [i 0 s 0] (if (< i n) (recur (inc i) s) s))))

(println (run variant n))
