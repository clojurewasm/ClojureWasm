;; Fractal zoom: the cljw server, a thin boundary over the renderer registry.
;; Usage: cljw docs/examples/fractal/server.clj [port]   (default 8080)
;;
;; Serves the re-frame page (web/public, built by shadow-cljs), every wasm
;; kernel for the browser, and tiles rendered natively on cljw: each kernel on
;; zwasm jit and interp, plus cljw-clj (plain Clojure). The JVM engines (raster,
;; CUDA) are a separate server (jvm/); the page talks to it directly.
;;   GET /                       the page
;;   GET /js/**                  the compiled frontend
;;   GET /kernel.wasm?k=<id>     a kernel module, application/wasm
;;   GET /engines                {"engines":[...],"kernels":[...]}
;;   GET /tile?cx=&cy=&scale=&w=&h=&iter=&engine=
;;                               w*h*4 raw RGBA bytes, X-Render-Ms and X-Iters

(ns fractal.server
  (:require [cljw.http.server :as http]
            [clojure.java.io :as io]
            [clojure.string :as str]))

(def dir (.getParent (io/file *file*)))
(load-file (str dir "/mandel.clj"))
(load-file (str dir "/cljw/tile.clj"))
(load-file (str dir "/cljw/renderer.clj"))
(load-file (str dir "/cljw/engines.clj"))

(def public (str dir "/web/public"))
(def port (if (seq *command-line-args*) (Long/parseLong (first *command-line-args*)) 8080))

;; --- Collect ---------------------------------------------------------------------
;; cljw's InputStream surface is the 1-arg .read, so drain into a sized array.
(defn file->bytes [path]
  (let [size (.length (io/file path))]
    (with-open [in (io/input-stream (io/file path))]
      (let [arr (byte-array size)]
        (dotimes [i size]
          (let [b (.read in)]
            (when (neg? b) (throw (ex-info "file shrank under read" {:path path :at i})))
            (aset arr i (unchecked-byte b))))
        arr))))

(def registry (fractal.cljw.renderer/registry
               (fractal.cljw.engines/discover dir fractal.mandel/render)))
(def kernel-bytes (into {} (map (fn [[k path]] [k (file->bytes path)]))
                        (fractal.cljw.engines/kernel-files dir)))

;; --- responses (pure, given the registry) ------------------------------------------
(defn json-strings [xs] (str "[" (str/join "," (map #(str "\"" % "\"") xs)) "]"))

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

(defn tile-response [q]
  (try
    (let [t (fractal.cljw.tile/parse-query q)
          engine (get q "engine" "zig-jit")]
      (if-let [rr (get registry engine)]
        (let [{:keys [ms iters rgba]} (fractal.cljw.renderer/frame rr t)]
          {:status 200
           :headers {"content-type" "application/octet-stream"
                     "cache-control" "no-store"
                     "x-render-ms" (format "%.3f" ms)
                     "x-iters" (str iters)}
           :body rgba})
        {:status 400 :body (str "engine must be one of " (vec (keys registry)))}))
    (catch Throwable e
      {:status 400 :body (str "tile error: " (.getMessage e))})))

;; --- Boundary ------------------------------------------------------------------------
(defn handler [req]
  (let [q (fractal.cljw.tile/query-map (:query-string req))]
    (case (:uri req)
      "/" {:status 200
           :headers {"content-type" "text/html; charset=utf-8"}
           :body (slurp (str public "/index.html"))}
      "/kernel.wasm" (if-let [bytes (get kernel-bytes (get q "k" "zig"))]
                       {:status 200
                        :headers {"content-type" "application/wasm" "cache-control" "no-cache"}
                        :body bytes}
                       {:status 404 :body "unknown kernel\n"})
      "/engines" {:status 200
                  :headers {"content-type" "application/json"}
                  :body (str "{\"engines\":" (json-strings (keys registry))
                             ",\"kernels\":" (json-strings (keys kernel-bytes)) "}")}
      "/tile" (tile-response q)
      (static (:uri req)))))

(println (str "fractal server on http://localhost:" port
              "  engines=" (vec (keys registry))))
(http/run-server handler {:port port})
