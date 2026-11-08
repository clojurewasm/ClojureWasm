;; The renderer port on cljw. Renderers are an open set (a wasm kernel per
;; language and zwasm runtime, plain Clojure, more later): each is an IRenderer
;; value in a registry. Every renderer paints the RGBA8 framebuffer itself; the
;; golden views prove they all paint the same bytes.
(ns fractal.cljw.renderer)

(defprotocol IRenderer
  (id [r] "Engine name as the page and the bench show it.")
  (describe [r] "{:interp? bool :what str}; interpreted engines skip heavy views.")
  (render! [r t] "Render Tile t: {:iters total :rgba byte-array}."))

(defn frame
  "Render Tile t on r, timed: {:iters :rgba :ms}."
  [r t]
  (let [t0 (System/nanoTime)
        out (render! r t)]
    (assoc out :ms (/ (double (- (System/nanoTime) t0)) 1.0e6))))

(defn registry [renderers] (into (array-map) (map (fn [r] [(id r) r])) renderers))
