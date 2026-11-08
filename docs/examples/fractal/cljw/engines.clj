;; Adapters and discovery on cljw. A wasm kernel (Zig, Zig simd128, C, Rust)
;; answers one ABI (README "The kernel ABI"), so one adapter serves every
;; kernel on every zwasm runtime. cljw-clj renders with plain Clojure
;; (../mandel.clj), no wasm. Kernels are data; a missing .wasm file is skipped.
(ns fractal.cljw.engines
  (:require [clojure.java.io :as io]
            [fractal.cljw.renderer :as r]))

(def kernel-specs
  "id, file under the fractal dir, render export, and :jit-only for simd128
  (zwasm's interpreter has no v128)."
  [{:id "zig" :file "kernel.wasm" :export "render"}
   {:id "zig-simd" :file "kernel_simd.wasm" :export "render_simd" :jit-only true}
   {:id "c" :file "kernel_c.wasm" :export "render"}
   {:id "rust" :file "kernel_rust.wasm" :export "render"}])

;; The view lives in the wasm instance, so set_view + render is one critical
;; section per instance.
(defrecord WasmKernel [rid runtime inst lock export]
  r/IRenderer
  (id [_] rid)
  (describe [_] {:interp? (= runtime :interp) :what (str export " on zwasm " (name runtime))})
  (render! [_ {:keys [cx cy scale w h iter]}]
    (locking lock
      (when (neg? (.set_view inst cx cy scale))
        (throw (ex-info "set_view rejected a non-finite coordinate" {:cx cx :cy cy :scale scale})))
      (let [iters (wasm/call inst export w h iter)]
        {:iters iters
         :rgba (wasm/mem-read-array inst :u8 (.fb_ptr inst) (* w h 4))}))))

(defrecord ClojureRaster [rid render-fn]
  r/IRenderer
  (id [_] rid)
  (describe [_] {:interp? true :what "plain Clojure on cljw, no wasm"})
  (render! [_ {:keys [cx cy scale w h iter]}]
    (let [fb (byte-array (* w h 4))]
      {:iters (render-fn fb cx cy scale w h iter) :rgba fb})))

(defn wasm-kernels
  "Every kernel file present under dir, on every runtime it supports."
  [dir specs]
  (for [{:keys [id file export jit-only]} specs
        :let [path (str dir "/" file)]
        :when (.exists (io/file path))
        runtime [:jit :interp]
        :when (not (and jit-only (= runtime :interp)))]
    (->WasmKernel (str id "-" (name runtime)) runtime
                  (wasm/load path {:engine runtime :fuel 0}) (Object.) export)))

(defn discover
  "All renderers available under dir: the wasm kernels, then cljw-clj."
  [dir render-fn]
  (concat (wasm-kernels dir kernel-specs) [(->ClojureRaster "cljw-clj" render-fn)]))

(defn kernel-files
  "{id path} of the kernels the browser can fetch."
  [dir]
  (into (array-map)
        (for [{:keys [id file]} kernel-specs
              :let [path (str dir "/" file)]
              :when (.exists (io/file path))]
          [id path])))
