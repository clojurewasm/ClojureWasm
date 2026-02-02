#!/usr/bin/env clojure -M
;; clj_warm_bench.clj — Warm JVM benchmark runner
;;
;; Usage: clojure -M bench/clj_warm_bench.clj bench/benchmarks/01_fib_recursive/bench.clj
;;
;; Warm-up: 3 iterations (discarded)
;; Measure: 5 iterations (report median nanoseconds)

(defn median [coll]
  (let [sorted (sort coll)
        n (count sorted)]
    (nth sorted (quot n 2))))

(defn run-bench [file warmup-count measure-count]
  ;; Warm-up
  (dotimes [_ warmup-count]
    (with-out-str (load-file file)))

  ;; Measure
  (let [times (for [_ (range measure-count)]
                (let [start (System/nanoTime)
                      _ (with-out-str (load-file file))
                      end (System/nanoTime)]
                  (- end start)))
        med (median (vec times))
        med-ms (/ med 1e6)]
    (println (format "Warm benchmark: %s" file))
    (println (format "  Warmup:  %d iterations" warmup-count))
    (println (format "  Measure: %d iterations" measure-count))
    (println (format "  Median:  %.0f ns (%.2f ms)" (double med) med-ms))
    med))

(let [args *command-line-args*]
  (if (empty? args)
    (do
      (println "Usage: clojure -M bench/clj_warm_bench.clj <bench.clj>")
      (System/exit 1))
    (run-bench (first args) 3 5)))
