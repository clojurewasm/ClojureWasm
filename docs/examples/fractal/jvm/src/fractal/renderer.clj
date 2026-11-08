(ns fractal.renderer
  "The renderer port. Renderers are an open set (CPU threads, SIMD lanes, GPU,
  and whatever comes next), so each one is an IRenderer value, discovered at
  start-up into a registry. A renderer computes the EscapeField only; the
  palette is applied once, above the port, so every renderer that computes the
  same escape field paints the same bytes."
  (:require [fractal.palette :as palette]
            [fractal.tile :as tile]
            [fractal.formula :as formula]))

(defprotocol IRenderer
  (id [r] "Engine name as the page and the bench show it.")
  (describe [r] "{:parity? bool :heavy? bool :what str :formulas #{id} :julia? bool}.
                 :parity? false for renderers whose arithmetic differs (fp32),
                 excluded from golden checks; :heavy? true when billion-iteration
                 views are practical; :formulas the fractal.formula ids it
                 renders (absent: Mandelbrot only); :julia? whether it renders
                 the z-plane seed.")
  (escape! [r t field] "Fill the EscapeField `field` for Tile t."))

(defn formulas
  "The formula ids r renders. A renderer that names none is Mandelbrot only,
  so a new formula costs no adapter that does not opt in."
  [r]
  (or (:formulas (describe r)) #{formula/default-id}))

(defn renders?
  "Whether r can render Tile t: its formula, and its seed."
  [r t]
  (and (contains? (formulas r) (:formula t formula/default-id))
       (or (nil? (:julia t)) (boolean (:julia? (describe r))))))

(defn frame
  "Render Tile t on r: {:iters :ms :rgba}. :ms covers the escape computation
  only; painting is shared work and timed apart as :paint-ms."
  [r t]
  (let [field (tile/escape-field t)
        t0 (System/nanoTime)
        _ (escape! r t field)
        t1 (System/nanoTime)
        rgba (palette/paint field t)
        t2 (System/nanoTime)]
    {:iters (tile/total-iters field)
     :ms (/ (- t1 t0) 1.0e6)
     :paint-ms (/ (- t2 t1) 1.0e6)
     :rgba rgba}))

;; Availability is data: a renderer that cannot start (no GPU, missing native
;; library) is an {:id :unavailable reason} row, not an exception at start-up.
(defn available
  "Run each [id constructor] and split the results."
  [constructors]
  (reduce (fn [acc [rid ctor]]
            (try (update acc :renderers conj (ctor))
                 (catch Throwable e
                   (update acc :unavailable conj
                           {:id rid :reason (str (.getSimpleName (class e)) ": " (.getMessage e))}))))
          {:renderers [] :unavailable []}
          constructors))

(defn registry [renderers] (into (array-map) (map (juxt id identity)) renderers))
