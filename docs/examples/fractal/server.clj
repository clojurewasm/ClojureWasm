;; Fractal zoom: the server half.
;; Usage: cljw docs/examples/fractal/server.clj [port]        (default 8080)
;;        KERNEL=/path/to/kernel.wasm cljw server.clj         (override the zig module)
;;
;; Native cljw serves the page and renders tiles server-side. Every kernel
;; (Zig, Zig simd128, C, Rust) answers one ABI, see README.md "The kernel ABI",
;; so the same render-tile drives all of them. cljw-raster renders with plain
;; Clojure (raster.clj) and no wasm, the CPU raster baseline.
;;
;; Engines (the /tile `engine` parameter) are "<kernel>-<runtime>":
;;   zig-jit zig-interp c-jit c-interp rust-jit rust-interp zig-simd-jit
;;   cljw-raster
;; The old names jit, interp and jit-simd stay as aliases of the zig ones.
;; GET /engines answers {"engines":[...],"kernels":[...]}; every kernel listed
;; is fetchable by the browser at GET /kernel.wasm?k=<id>.
;;
;; The view lives in the wasm instance, so set_view + render is atomic per
;; instance: every instance is held behind a lock.

(ns fractal.server
  (:require [cljw.http.server :as http]
            [clojure.java.io :as io]
            [clojure.string :as str]))

(def dir (.getParent (io/file *file*)))
(load-file (str dir "/mandel.clj"))
(def public (str dir "/web/public"))

(def port (if (seq *command-line-args*)
            (Long/parseLong (first *command-line-args*))
            8080))

;; --- kernels ------------------------------------------------------------------
;; :jit-only marks simd128 modules: zwasm's interpreter has no v128.
(def kernel-specs
  [{:id "zig" :path (or (System/getenv "KERNEL") (str dir "/kernel.wasm")) :export "render"}
   {:id "zig-simd" :path (str dir "/kernel_simd.wasm") :export "render_simd" :jit-only true}
   {:id "c" :path (str dir "/kernel_c.wasm") :export "render"}
   {:id "rust" :path (str dir "/kernel_rust.wasm") :export "render"}])

(def kernels (filterv #(.exists (io/file (:path %))) kernel-specs))

;; --- file bytes ---------------------------------------------------------------
;; cljw's InputStream surface is the 1-arg .read (one byte per call), so drain
;; into a pre-sized array.
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

(def kernel-bytes (into {} (map (fn [k] [(:id k) (file->bytes (:path k))])) kernels))

;; --- engines --------------------------------------------------------------------
;; An engine is {:inst :lock :export} for wasm, or {:raster true :lock}.
(defn wasm-engine [k runtime]
  {:inst (wasm/load (:path k) {:engine runtime :fuel 0})
   :lock (Object.)
   :export (:export k)})

(def engines
  (into (array-map)
        (concat
         (for [k kernels
               runtime [:jit :interp]
               :when (not (and (:jit-only k) (= runtime :interp)))]
           [(str (:id k) "-" (name runtime)) (wasm-engine k runtime)])
         [["cljw-clj" {:clj true :lock (Object.)}]])))

(def aliases {"jit" "zig-jit" "interp" "zig-interp" "jit-simd" "zig-simd-jit"})

(def cap (.fb_cap (:inst (get engines "zig-jit"))))

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
;; The wasm framebuffer is read back in one bulk copy as a byte-array, which is
;; also the response body verbatim.
(defn render-tile [eng cx cy scale w h iter]
  (when (> (* w h) cap)
    (throw (ex-info "tile exceeds framebuffer capacity" {:cap cap :got (* w h)})))
  (locking (:lock eng)
    (if (:clj eng)
      (let [fb (byte-array (* w h 4))
            t0 (System/nanoTime)
            iters (fractal.mandel/render fb cx cy scale w h iter)]
        {:ms (/ (double (- (System/nanoTime) t0)) 1.0e6) :iters iters :bytes fb})
      (let [inst (:inst eng)
            rc (.set_view inst cx cy scale)]
        (when (neg? rc)
          (throw (ex-info "set_view rejected a non-finite coordinate" {:cx cx :cy cy :scale scale})))
        (let [t0 (System/nanoTime)
              iters (wasm/call inst (:export eng) w h iter)
              ms (/ (double (- (System/nanoTime) t0)) 1.0e6)]
          {:ms ms :iters iters
           :bytes (wasm/mem-read-array inst :u8 (.fb_ptr inst) (* w h 4))})))))

;; --- static files ---------------------------------------------------------------
;; The compiled frontend: /js/** from web/public/js. No path may climb out.
(def content-types {"js" "text/javascript" "map" "application/json" "css" "text/css"})

(defn static [uri]
  (let [f (io/file (str public uri))
        ext (subs uri (inc (.lastIndexOf uri ".")))]
    (if (and (.startsWith uri "/js/") (not (.contains uri "..")) (.isFile f))
      {:status 200
       :headers {"content-type" (get content-types ext "application/octet-stream")
                 "cache-control" "no-cache"}
       :body (file->bytes (.getPath f))}
      {:status 404 :body "not found\n"})))

;; --- handler ------------------------------------------------------------------
(defn json-strings [xs]
  (str "[" (str/join "," (map #(str "\"" % "\"") xs)) "]"))

(defn handler [req]
  (let [q (parse-query (:query-string req))]
    (case (:uri req)
      "/" {:status 200
           :headers {"content-type" "text/html; charset=utf-8"}
           :body (slurp (str public "/index.html"))}

      "/kernel.wasm"
      (if-let [bytes (get kernel-bytes (get q "k" "zig"))]
        {:status 200
         :headers {"content-type" "application/wasm" "cache-control" "no-cache"}
         :body bytes}
        {:status 404 :body "unknown kernel\n"})

      "/engines" {:status 200
                  :headers {"content-type" "application/json"}
                  :body (str "{\"engines\":" (json-strings (keys engines))
                             ",\"kernels\":" (json-strings (map :id kernels)) "}")}

      "/tile"
      (try
        (let [cx (num q "cx" -0.6)
              cy (num q "cy" 0.0)
              scale (num q "scale" 0.004)
              w (lng q "w" 640)
              h (lng q "h" 480)
              iter (lng q "iter" 256)
              id (get q "engine" "zig-jit")
              eng (get engines (get aliases id id))]
          (if (nil? eng)
            {:status 400 :body (str "engine must be one of " (vec (keys engines)))}
            (let [{:keys [ms iters bytes]} (render-tile eng cx cy scale w h iter)]
              {:status 200
               :headers {"content-type" "application/octet-stream"
                         "cache-control" "no-store"
                         "x-render-ms" (format "%.3f" ms)
                         "x-iters" (str iters)}
               :body bytes})))
        (catch Throwable e
          {:status 400 :body (str "tile error: " (.getMessage e))}))

      (static (:uri req)))))

(println (str "fractal server on http://localhost:" port
              "  kernels=" (mapv :id kernels)
              "  engines=" (vec (keys engines))))
(http/run-server handler {:port port})
