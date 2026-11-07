(ns fractal.view
  "The complex-plane view as a value: {:cx :cy :scale}, where scale is the
  plane distance of one canvas pixel. Pure functions only.")

(def home {:cx -0.6 :cy 0.0 :scale (/ 3.0 800)})

(def tour-target {:cx -0.743643887037151 :cy 0.13182590420533})

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

(defn ->hash [{:keys [cx cy scale]} iter]
  (str \# (js/URLSearchParams. #js {:cx cx :cy cy :scale scale :iter iter})))

(defn <-hash
  "Parse a location hash into {:view {...} :iter n}; keys absent or invalid
  in the hash are absent from the result."
  [hash]
  (let [p (js/URLSearchParams. (subs (or hash "") 1))
        n #(when (.has p %) (finite-num (.get p %)))
        v (cond-> {}
            (n "cx") (assoc :cx (n "cx"))
            (n "cy") (assoc :cy (n "cy"))
            (some-> (n "scale") pos?) (assoc :scale (n "scale")))]
    (cond-> {:view v}
      (n "iter") (assoc :iter (max 1 (js/Math.round (n "iter")))))))
