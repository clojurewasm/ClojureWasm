;; ClojureWasm SIMD benchmark runner
;; Usage: ./zig-out/bin/cljw bench/simd/bench_cw.clj

(require '[cljw.wasm :as wasm])

(defn bench-wasm [name wasm-file func-name & init-fns]
  (let [mod (wasm/load wasm-file)]
    ;; Run init functions if any
    (doseq [init-fn init-fns]
      (let [f (wasm/fn mod init-fn)]
        (f)))
    ;; Benchmark
    (let [f (wasm/fn mod func-name)
          start (System/nanoTime)
          result (f)
          end (System/nanoTime)
          ms (/ (- end start) 1000000.0)]
      (println (str name ": " (format "%.2f" ms) " ms (result=" result ")")))))

(bench-wasm "mandelbrot" "bench/simd/mandelbrot.wasm" "mandelbrot")

(bench-wasm "vector_add" "bench/simd/vector_add.wasm" "vector_add" "init")

(bench-wasm "dot_product" "bench/simd/dot_product.wasm" "dot_product" "init")

(bench-wasm "matrix_mul" "bench/simd/matrix_mul.wasm" "matrix_mul" "init")
