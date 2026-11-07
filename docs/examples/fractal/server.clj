;; Fractal zoom: the server half.
;; Usage: cljw docs/examples/fractal/server.clj [port]        (default 8080)
;;        KERNEL=/path/to/kernel.wasm cljw server.clj         (override module)
;;
;; Native cljw serves the page and renders tiles server-side with zwasm; the
;; browser ALSO runs the identical kernel.wasm locally and compares live.
;;
;; kernel.wasm ABI (fixed): no imports; exports `memory`, `fb_ptr() -> i32`,
;; `fb_cap() -> i32`, `set_view(cx f64, cy f64, scale f64) -> i32` (0 finite,
;; -1 nonfinite), and `render(w i32, h i32, max_iter i32) -> i64` writing w*h
;; RGBA8 row-major pixels at fb_ptr and returning total iterations.
;; `render_simd` (same 3 args) ships only in a sibling kernel_simd.wasm; the
;; zwasm interpreter cannot run SIMD, so the interp instance always uses the
;; scalar render. The view lives in the instance, so set_view + render is
;; atomic per instance: every instance is held behind a lock.
;;
;; Engines (the /tile `engine` parameter):
;;   jit       kernel.wasm on zwasm's JIT
;;   jit-simd  kernel_simd.wasm on the JIT (only when that file exists)
;;   interp    kernel.wasm on zwasm's interpreter
;; GET /engines answers which of these exist, e.g. {"engines":["jit","interp"]}.
;;
;; Binary bodies: cljw.http.server accepts a primitive byte-array :body and
;; copies it verbatim, so tiles and the wasm module itself cross as raw bytes
;; (a String cannot carry arbitrary binary: its producers normalise to UTF-8).

(ns fractal.server
  (:require [cljw.http.server :as http]
            [clojure.java.io :as io]))

(def dir (.getParent (io/file *file*)))
(def kernel-path (or (System/getenv "KERNEL") (str dir "/kernel.wasm")))
(def simd-path (str dir "/kernel_simd.wasm"))

(def port (if (seq *command-line-args*)
            (Long/parseLong (first *command-line-args*))
            8080))

;; --- one instance per engine, each behind its own lock -----------------------
;; [handle lock]; the lock makes the set_view + render pair atomic per
;; request: the view is instance state and the accept loop may thread later.
(defn engine [path eng simd?]
  [(wasm/load path {:engine eng :fuel 0})
   (Object.)
   (if simd? "render_simd" "render")])

(def jit (engine kernel-path :jit false))
(def interp (engine kernel-path :interp false))
(def jit-simd
  (when (.exists (io/file simd-path))
    (engine simd-path :jit true)))

(def engines
  (cond-> ["jit" "interp"]
    (some? jit-simd) (conj "jit-simd")))

(def cap (.fb_cap (first jit)))

;; --- file bytes ---------------------------------------------------------------
;; Read a whole file as a primitive byte-array. cljw's InputStream surface
;; today is the 1-arg .read (one byte per call, 0..255, -1 at EOF); there is
;; no readAllBytes / .read(buf) arm, so drain into a pre-sized array.
(defn file->bytes [path]
  (let [size (.length (io/file path))]
    (with-open [in (io/input-stream (io/file path))]
      (let [arr (byte-array size)]
        (dotimes [i size]
          (let [b (.read in)]
            (when (neg? b)
              (throw (ex-info "file shrank under read" {:path path :at i})))
            (aset arr i (unchecked-byte b))))
        arr))))

(def kernel-bytes (file->bytes kernel-path))

;; --- query parsing ------------------------------------------------------------
(defn parse-query [qs]
  (if (nil? qs)
    {}
    (into {}
          (keep (fn [pair]
                  (let [i (.indexOf pair "=")]
                    (when (pos? i)
                      [(subs pair 0 i) (subs pair (inc i))]))))
          (.split qs "&"))))

(defn num [m k d]
  (let [v (get m k)]
    (if (nil? v) d (Double/parseDouble v))))

(defn lng [m k d]
  (let [v (get m k)]
    (if (nil? v) d (Long/parseLong v))))

;; --- tile rendering -----------------------------------------------------------
;; `eng` is an engine triple. set_view validates the view (0) before render;
;; the pair is locked per instance. The framebuffer is read back in one bulk
;; memcpy as a byte-array, which is also the response body verbatim.
(defn render-tile [eng cx cy scale w h iter]
  (when (> (* w h) cap)
    (throw (ex-info "tile exceeds framebuffer capacity" {:cap cap :got (* w h)})))
  (let [[inst lock f] eng]
    (locking lock
      (let [rc (.set_view inst cx cy scale)]
        (when (neg? rc)
          (throw (ex-info "set_view rejected a non-finite coordinate" {:cx cx :cy cy :scale scale}))))
      (let [t0 (System/nanoTime)
            iters (if (= f "render_simd")
                    (.render_simd inst w h iter)
                    (.render inst w h iter))
            ms (/ (double (- (System/nanoTime) t0)) 1.0e6)
            arr (wasm/mem-read-array inst :u8 (.fb_ptr inst) (* w h 4))]
        {:ms ms :iters iters :bytes arr}))))

;; --- handler ------------------------------------------------------------------
(defn handler [req]
  (case (:uri req)
    "/" {:status 200
         :headers {"content-type" "text/html; charset=utf-8"}
         :body (slurp (str dir "/index.html"))}

    "/kernel.wasm" {:status 200
                    :headers {"content-type" "application/wasm"
                              "cache-control" "no-cache"}
                    :body kernel-bytes}

    "/engines" {:status 200
                :headers {"content-type" "application/json"}
                :body (str "{\"engines\":[" (clojure.string/join "," (map #(str "\"" % "\"") engines)) "]}")}

    "/tile"
    (try
      (let [q (parse-query (:query-string req))
            cx (num q "cx" -0.6)
            cy (num q "cy" 0.0)
            scale (num q "scale" 0.004)
            w (lng q "w" 640)
            h (lng q "h" 480)
            iter (lng q "iter" 256)
            eng (case (get q "engine" "jit")
                  "jit" jit
                  "jit-simd" jit-simd
                  "interp" interp
                  nil)]
        (if (nil? eng)
          {:status 400 :body (str "engine must be one of " engines)}
          (let [{:keys [ms iters bytes]} (render-tile eng cx cy scale w h iter)]
            {:status 200
             :headers {"content-type" "application/octet-stream"
                       "cache-control" "no-store"
                       "x-render-ms" (format "%.3f" ms)
                       "x-iters" (str iters)}
             :body bytes})))
      (catch Throwable e
        {:status 400 :body (str "tile error: " (.getMessage e))}))

    {:status 404 :body "not found\n"}))

(println (str "fractal server on http://localhost:" port
              "  kernel=" kernel-path
              "  engines=" engines))
(http/run-server handler {:port port})
