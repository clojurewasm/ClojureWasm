(ns fractal.renderer.cuda
  "CUDA renderers through uncomplicate/clojurecuda: one GPU thread per pixel.
  escape.cu is compiled at start-up by NVRTC straight to a CUBIN for this GPU
  (SASS, no PTX JIT, so a toolkit newer than the driver still loads). A CUDA
  context is current per thread, so the adapter owns ONE worker thread that
  creates the context and runs every GPU call; callers never see CUDA thread
  affinity. fp64 with --fmad=false rounds like the JVM (golden parity); fp32
  trades exactness for the GPU's single-precision throughput."
  (:require [clojure.java.io :as io]
            [uncomplicate.clojurecuda.core :as cu]
            [uncomplicate.clojure-cpp :as cpp]
            [uncomplicate.commons.core :as cc]
            [fractal.renderer :as r]
            [fractal.tile :as tile])
  (:import (java.util.concurrent Callable ExecutorService Executors ThreadFactory)
           (org.bytedeco.cuda.global nvrtc)
           (org.bytedeco.cuda.nvrtc _nvrtcProgram)
           (org.bytedeco.javacpp BytePointer DoublePointer IntPointer SizeTPointer)))

;; --- Boundary: the GPU worker -------------------------------------------------
(defn- on-gpu
  "Run f on the worker thread and return its value, rethrowing its exception."
  [^ExecutorService worker f]
  (.get (.submit worker ^Callable f)))

(defn- cubin
  "The compiled CUBIN of an NVRTC program, as bytes."
  ^bytes [prog]
  (let [size (SizeTPointer. 1)]
    (nvrtc/nvrtcGetCUBINSize ^_nvrtcProgram prog size)
    (let [n (.get size 0)
          bp (BytePointer. n)
          out (byte-array n)]
      (nvrtc/nvrtcGetCUBIN ^_nvrtcProgram prog bp)
      (.get bp out)
      out)))

(defn- sm-arch
  "-arch=sm_XY for device dev, from its compute capability."
  [dev]
  (let [{:keys [compute-capability-major compute-capability-minor]}
        (cc/info dev [:compute-capability-major :compute-capability-minor])]
    (str "-arch=sm_" compute-capability-major compute-capability-minor)))

(defn- open-gpu
  "On the worker: context, compiled module and kernel functions."
  []
  (cu/init)
  (let [dev (cu/device 0)
        ctx (cu/context dev)]
    (cu/current-context! ctx)
    (let [prog (cu/compile! (cu/program (slurp (io/resource "fractal/escape.cu")))
                            ["--fmad=false" (sm-arch dev)])
          m (cu/module (cubin prog))]
      {:ctx ctx
       :device (str (cc/info dev :name))
       :kernels {:f64 (cu/function m "escape_f64") :f32 (cu/function m "escape_f32")}})))

(defn- escape-on-gpu!
  "On the worker: launch kernel for tile t and copy the field back."
  [kernel {:keys [cx cy scale w h iter] :as t} {:keys [^ints counts ^doubles mag2]}]
  (let [n (tile/pixels t)]
    (cc/with-release [d-counts (cu/mem-alloc-driver (* 4 n))
                      d-mag2 (cu/mem-alloc-driver (* 8 n))
                      h-counts (cpp/int-pointer n)
                      h-mag2 (cpp/double-pointer n)]
      (cu/launch! kernel (cu/grid-2d w h 16 16)
                  (cu/parameters d-counts d-mag2 (int w) (int h)
                                 (double cx) (double cy) (double scale) (int iter)))
      (cu/synchronize!)
      (cu/memcpy-host! d-counts h-counts)
      (cu/memcpy-host! d-mag2 h-mag2)
      (.get ^IntPointer h-counts counts)
      (.get ^DoublePointer h-mag2 mag2))))

;; --- the renderers ----------------------------------------------------------------
(defrecord Cuda [rid precision gpu worker]
  r/IRenderer
  (id [_] rid)
  (describe [_] {:parity? (= precision :f64)
                 :what (str "CUDA " (name precision) " on " (:device gpu))})
  (escape! [_ t field]
    (on-gpu worker #(escape-on-gpu! (get-in gpu [:kernels precision]) t field))))

(defonce ^:private shared (delay
                            (let [worker (Executors/newSingleThreadExecutor
                                          (reify ThreadFactory
                                            (newThread [_ run]
                                              (doto (Thread. run "fractal-cuda") (.setDaemon true)))))]
                              {:worker worker :gpu (on-gpu worker open-gpu)})))

(defn f64 [] (let [{:keys [gpu worker]} @shared] (->Cuda "cuda-f64" :f64 gpu worker)))
(defn f32 [] (let [{:keys [gpu worker]} @shared] (->Cuda "cuda-f32" :f32 gpu worker)))
