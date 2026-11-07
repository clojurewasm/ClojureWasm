;; Run from the repository root: zig-out/bin/cljw docs/examples/fractal/bench.clj
;; Render timing excludes framebuffer transfer, checksum and PPM encoding.
;; CLJW_FRACTAL_CI=1 selects small correctness cases for the e2e gate.
(ns fractal.bench (:require [clojure.java.io :as io]))

(def root "docs/examples/fractal/")
(def views
  (if (= "1" (System/getenv "CLJW_FRACTAL_CI"))
    [{:name "full" :cx -0.5 :cy 0.0 :scale (/ 3.5 32) :w 32 :h 32 :iter 64}
     {:name "seahorse" :cx -0.743643887037151 :cy 0.13182590420533 :scale 1.0e-6 :w 16 :h 16 :iter 160}
     {:name "odd-tail" :cx -0.5 :cy 0.0 :scale 0.1 :w 31 :h 29 :iter 80}]
    [{:name "full" :cx -0.5 :cy 0.0 :scale (/ 3.5 512) :w 512 :h 512 :iter 256}
     {:name "seahorse" :cx -0.743643887037151 :cy 0.13182590420533 :scale 1.0e-6 :w 128 :h 128 :iter 2000}
     {:name "odd-tail" :cx -0.5 :cy 0.0 :scale 0.1 :w 31 :h 29 :iter 80}]))

(defn checksum [pixels]
  (reduce (fn [acc b] (mod (+ (* acc 31) (bit-and 255 b)) 2147483647)) 1 pixels))

(defn ppm! [pixels w h]
  ;; P3 is portable text PPM, avoiding host-specific binary stream methods.
  (with-open [out (io/writer (str root "out.ppm"))]
    (.write out (str "P3\n" w " " h "\n255\n"))
    (dotimes [i (* w h)]
      (.write out (str (bit-and 255 (aget pixels (* i 4))) " "
                       (bit-and 255 (aget pixels (+ (* i 4) 1))) " "
                       (bit-and 255 (aget pixels (+ (* i 4) 2))) "\n")))))

(def references (atom {}))
(defn run-frame! [module engine export view]
  (let [{:keys [name cx cy scale w h iter]} view
        _ (assert (= 0 (.set_view module cx cy scale)))
        start (System/nanoTime)
        iterations (wasm/call module export w h iter)
        ms (/ (- (System/nanoTime) start) 1.0e6)
        pixels (wasm/mem-read-array module :u8 (.fb_ptr module) (* w h 4))
        sum (checksum pixels)
        result [iterations sum]]
    (println engine export name "ms" ms "Miter/s" (/ iterations (* ms 1000.0))
             "iterations" iterations "checksum" sum)
    (if-let [reference (get @references name)]
      (assert (= reference result) (str "parity mismatch: " engine " " export " " name))
      (swap! references assoc name result))
    (when (and (= engine :interp) (= export "render") (= name "full"))
      (ppm! pixels w h))))

(doseq [engine [:jit :interp]]
  (let [module (wasm/load (str root "kernel.wasm") {:engine engine :fuel 0})]
    (let [exports (wasm/exports module)]
      (println "exports" engine exports)
      (doseq [export ["render" "render_simd"]]
        (let [signature (first (filter #(= export (:name %)) exports))]
          (assert (= [:i32 :i32 :i32] (:params signature)))
          (assert (= [:i64] (:results signature))))))
    (assert (= 1048576 (.fb_cap module)))
    (doseq [export ["render" "render_simd"] view views]
      (run-frame! module engine export view))))
(println "PASS scalar artifact: strict engine and vector-source parity")

;; SIMD instructions are JIT-only in zwasm. Keep this artifact separate so the
;; scalar module remains usable by the interpreter and browsers without SIMD.
(let [module (wasm/load (str root "kernel_simd.wasm") {:engine :jit :fuel 0})]
  (doseq [export ["render" "render_simd"] view views]
    (run-frame! module :jit-simd export view))
  (println "PASS simd128 JIT strict parity"))
(println "Wrote docs/examples/fractal/out.ppm")
