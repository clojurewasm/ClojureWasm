;; Run from the repository root: zig-out/bin/cljw docs/examples/fractal/bench.clj
;; Every kernel (Zig, Zig simd128, C, Rust) on every zwasm runtime, plus the
;; pure Clojure raster (raster.clj, no wasm). Render timing excludes the
;; framebuffer transfer, checksum and PPM encoding.
;; Parity asserted: iteration totals are equal across ALL engines; checksums are
;; equal across runtimes and exports of one kernel; the Zig scalar and simd128
;; modules agree byte for byte, and so do C and Rust (they share one log2).
;; CLJW_FRACTAL_CI=1 selects small correctness cases for the e2e gate.
;; RASTER=0 skips the pure Clojure raster.
(ns fractal.bench (:require [clojure.java.io :as io]))

(def root "docs/examples/fractal/")
(load-file (str root "mandel.clj"))

(def views
  (if (= "1" (System/getenv "CLJW_FRACTAL_CI"))
    [{:name "full" :cx -0.5 :cy 0.0 :scale (/ 3.5 32) :w 32 :h 32 :iter 64}
     {:name "seahorse" :cx -0.743643887037151 :cy 0.13182590420533 :scale 1.0e-6 :w 16 :h 16 :iter 160}
     {:name "odd-tail" :cx -0.5 :cy 0.0 :scale 0.1 :w 31 :h 29 :iter 80}]
    [{:name "full" :cx -0.5 :cy 0.0 :scale (/ 3.5 512) :w 512 :h 512 :iter 256}
     {:name "seahorse" :cx -0.743643887037151 :cy 0.13182590420533 :scale 1.0e-6 :w 128 :h 128 :iter 2000}
     {:name "odd-tail" :cx -0.5 :cy 0.0 :scale 0.1 :w 31 :h 29 :iter 80}]))

;; Byte-identity groups: kernels in one group must produce identical pixels.
(def kernels
  [{:id "zig" :file "kernel.wasm" :group "zig" :runtimes [:jit :interp] :exports ["render" "render_simd"]}
   {:id "zig-simd" :file "kernel_simd.wasm" :group "zig" :runtimes [:jit] :exports ["render" "render_simd"]}
   {:id "c" :file "kernel_c.wasm" :group "c+rust" :runtimes [:jit :interp] :exports ["render"]}
   {:id "rust" :file "kernel_rust.wasm" :group "c+rust" :runtimes [:jit :interp] :exports ["render"]}])

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

(def results (atom []))
(def iteration-ref (atom {}))
(def checksum-ref (atom {}))

(defn record! [engine group view iterations ms pixels]
  (let [{:keys [name w h]} view
        sum (checksum pixels)]
    (println (format "%-26s %-9s %10.2f ms %8.2f Miter/s  iters %d  checksum %d"
                     engine name ms (/ iterations (* ms 1000.0)) iterations sum))
    (swap! results conj {:engine engine :view name :ms ms :iters iterations})
    (if-let [ref (get @iteration-ref name)]
      (assert (= ref iterations) (str "iteration mismatch: " engine " " name))
      (swap! iteration-ref assoc name iterations))
    (when group
      (if-let [ref (get @checksum-ref [group name])]
        (assert (= ref sum) (str "checksum mismatch in group " group ": " engine " " name))
        (swap! checksum-ref assoc [group name] sum)))
    (when (and (= engine "zig-interp/render") (= name "full"))
      (ppm! pixels w h))))

(defn run-wasm! [module engine group export view]
  (let [{:keys [cx cy scale w h iter]} view
        _ (assert (= 0 (.set_view module cx cy scale)))
        start (System/nanoTime)
        iterations (wasm/call module export w h iter)
        ms (/ (- (System/nanoTime) start) 1.0e6)
        pixels (wasm/mem-read-array module :u8 (.fb_ptr module) (* w h 4))]
    (record! engine group view iterations ms pixels)))

(doseq [{:keys [id file group runtimes exports]} kernels
        runtime runtimes]
  (let [module (wasm/load (str root file) {:engine runtime :fuel 0})
        sigs (wasm/exports module)]
    (doseq [export exports]
      (let [signature (first (filter #(= export (:name %)) sigs))]
        (assert (= [:i32 :i32 :i32] (:params signature)) (str id " " export " params"))
        (assert (= [:i64] (:results signature)) (str id " " export " results"))))
    (assert (= 1048576 (.fb_cap module)))
    (doseq [export exports view views]
      (run-wasm! module (str id "-" (name runtime) "/" export) group export view))))
(println "PASS wasm kernels: iteration parity across kernels, byte parity within groups")

(when-not (= "0" (System/getenv "RASTER"))
  (doseq [view views]
    (let [{:keys [cx cy scale w h iter]} view
          fb (byte-array (* w h 4))
          start (System/nanoTime)
          iterations (fractal.mandel/render fb cx cy scale w h iter)
          ms (/ (- (System/nanoTime) start) 1.0e6)]
      (record! "cljw-clj" nil view iterations ms fb)))
  (println "PASS cljw-raster: iteration parity with the wasm kernels"))

(println)
(println "| engine | view | ms | Miter/s |")
(println "|---|---|---:|---:|")
(doseq [{:keys [engine view ms iters]} @results]
  (println (format "| %s | %s | %.2f | %.2f |" engine view ms (/ iters (* ms 1000.0)))))
(println "Wrote docs/examples/fractal/out.ppm")
