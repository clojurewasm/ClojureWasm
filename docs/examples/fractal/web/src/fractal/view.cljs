(ns fractal.view
  "The complex-plane view as a value: {:cx :cy :scale}, where scale is the
  plane distance of one canvas pixel. Pure functions only.")

(def home {:cx -0.6 :cy 0.0 :scale (/ 3.0 800)})

(def tour-target {:cx -0.743643887037151 :cy 0.13182590420533})

(def default-fractal
  "Which set the page shows: a formula id of the JVM's fractal.formula
  registry, and k when the orbit starts on the z-plane (a Julia set)."
  {:formula "mandelbrot" :julia nil})

(def builtin-catalog
  "The formula every engine renders. Servers add the rest (GET /engines)."
  [{:id "mandelbrot" :what "z^2 + c" :home {:cx -0.5 :cy 0.0 :scale 0.0068359375} :julia [-0.8 0.156]}])

(defn plane-point
  "The complex point [re im] under canvas pixel (px, py) of a w x h canvas."
  [{:keys [cx cy scale]} [w h] [px py]]
  [(+ cx (* (- px (/ w 2)) scale)) (+ cy (* (- py (/ h 2)) scale))])

(defn home-of
  "The view that frames fractal f on a canvas w pixels wide. Catalog homes
  are for 512 pixels; a Julia set is framed as the disk of radius 1.7."
  [catalog {:keys [formula julia]} w]
  (let [k (/ 512 (max 1 w))
        entry (or (first (filter #(= formula (:id %)) catalog)) (first builtin-catalog))]
    (if julia
      {:cx 0 :cy 0 :scale (* k (/ 3.4 512))}
      (update (:home entry) :scale * k))))

(defn zoom-at
  "Zoom by factor (>1 in) keeping the plane point under canvas pixel (px, py)
  fixed, on a canvas of w x h pixels."
  [{:keys [cx cy scale] :as v} [w h] [px py] factor]
  (assoc v
         :cx (+ cx (* (- px (/ w 2)) scale (- 1 (/ 1 factor))))
         :cy (+ cy (* (- py (/ h 2)) scale (- 1 (/ 1 factor))))
         :scale (/ scale factor)))

(defn pan
  "Slide the view by (dx, dy) canvas pixels."
  [{:keys [scale] :as v} [dx dy]]
  (-> v (update :cx + (* dx scale)) (update :cy + (* dy scale))))

(defn zoom-level [{:keys [scale]}] (/ (:scale home) scale))

(defn pane-view
  "The view one pane renders: pane (dx, dw) of a W x H canvas, at resolution
  factor res. Panes are slices of one shared view, so a split seam is
  continuous."
  [{:keys [cx cy scale]} [W H] [dx dw] res]
  {:cx (+ cx (* (- (+ dx (/ dw 2)) (/ W 2)) scale))
   :cy cy
   :scale (/ scale res)
   :w (max 1 (js/Math.round (* dw res)))
   :h (max 1 (js/Math.round (* H res)))})

(defn tour-step
  "One frame of the tour: ease toward the target and zoom 4 percent."
  [v]
  (-> v
      (update :cx #(+ % (* 0.08 (- (:cx tour-target) %))))
      (update :cy #(+ % (* 0.08 (- (:cy tour-target) %))))
      (update :scale * 0.96)))

(defn tour-iter
  "Iteration cap that keeps detail as the tour zooms deeper."
  [v current]
  (min 4096 (max current (js/Math.round (+ 200 (* 60 (js/Math.log2 (zoom-level v))))))))

(defn finite-num [s]
  (let [n (js/Number s)]
    (when (and (some? s) (not= s "") (js/Number.isFinite n)) n)))

(defn valid? [{:keys [cx cy scale]}]
  (and (js/Number.isFinite cx) (js/Number.isFinite cy) (js/Number.isFinite scale) (pos? scale)))

(defn ->hash
  "The URL hash of view v at iteration cap iter for fractal f; the formula
  and k are written only when they differ from plain Mandelbrot."
  ([v iter] (->hash v iter default-fractal))
  ([{:keys [cx cy scale]} iter {:keys [formula julia]}]
   (let [p (js/URLSearchParams. #js {:cx cx :cy cy :scale scale :iter iter})]
     (when (and formula (not= formula (:formula default-fractal))) (.set p "formula" formula))
     (when-let [[kr ki] julia] (.set p "jr" kr) (.set p "ji" ki))
     (str \# p))))

(defn <-hash
  "Parse a location hash into {:view {...} :iter n :fractal {...}}; keys
  absent or invalid in the hash are absent from the result. :fractal is
  present when the hash names a formula or a Julia k."
  [hash]
  (let [p (js/URLSearchParams. (subs (or hash "") 1))
        n #(when (.has p %) (finite-num (.get p %)))
        v (cond-> {}
            (n "cx") (assoc :cx (n "cx"))
            (n "cy") (assoc :cy (n "cy"))
            (some-> (n "scale") pos?) (assoc :scale (n "scale")))
        julia (when (and (n "jr") (n "ji")) [(n "jr") (n "ji")])
        formula (when (seq (.get p "formula")) (.get p "formula"))]
    (cond-> {:view v}
      (n "iter") (assoc :iter (max 1 (js/Math.round (n "iter"))))
      (or formula julia) (assoc :fractal {:formula (or formula (:formula default-fractal))
                                          :julia julia}))))
