(ns fractal.tile
  "Domain values. A Tile is the question: {:cx :cy :scale :w :h :iter}, pixel
  (x, y) being the point (cx + (x - w/2) scale, cy + (y - h/2) scale). An
  EscapeField is the answer every renderer gives: per pixel the escape count
  (ints) and |z|^2 at escape (doubles). Pure functions only."
  (:require [fractal.formula :as formula]))

(def max-pixels (* 1024 1024))

(def max-iter (dec (bit-shift-left 1 26)))

(defn finite? [x] (and (number? x) (Double/isFinite (double x))))

(defn problems
  "Why m is not a Tile, or nil when it is one."
  [{:keys [cx cy scale w h iter formula julia]}]
  (not-empty
   (cond-> []
     (not (every? finite? [cx cy scale])) (conj "cx, cy and scale must be finite numbers")
     (and (finite? scale) (not (pos? scale))) (conj "scale must be positive")
     (not (and (int? w) (int? h) (pos? w) (pos? h))) (conj "w and h must be positive integers")
     (and (int? w) (int? h) (> (* w h) max-pixels)) (conj (str "w*h must be at most " max-pixels))
     (not (and (int? iter) (pos? iter))) (conj "iter must be a positive integer")
     (and formula (not (formula/known? formula))) (conj (str "unknown formula " formula))
     (and julia (not (and (sequential? julia) (= 2 (count julia)) (every? finite? julia))))
     (conj "julia must be [kr ki], two finite numbers"))))

(defn tile
  "Validate and normalise m into a Tile; throws ex-info listing the problems.
  :formula defaults to Mandelbrot; :julia is present only for the z-plane seed."
  [m]
  (if-let [p (problems m)]
    (throw (ex-info (first p) {:tile m :problems p}))
    (cond-> (-> (select-keys m [:cx :cy :scale :w :h :iter])
                (update :cx double) (update :cy double) (update :scale double)
                (update :iter #(min % max-iter))
                (assoc :formula (or (:formula m) formula/default-id)))
      (:julia m) (assoc :julia (mapv double (:julia m))))))

(defn pixels [{:keys [w h]}] (* w h))

(defn point
  "The complex point of pixel (x, y): [re im]."
  [{:keys [cx cy scale w h]} x y]
  [(+ cx (* (- (double x) (/ (double w) 2.0)) scale))
   (+ cy (* (- (double y) (/ (double h) 2.0)) scale))])

(defn seed
  "Where pixel (x, y)'s orbit starts, [zr zi cr ci]: z0 = 0 and c = the
  point on the c-plane; z0 = the point and c = k on the z-plane (Julia)."
  [t x y]
  (let [[pr pi] (point t x y)]
    (if-let [[kr ki] (:julia t)]
      [pr pi kr ki]
      [0.0 0.0 pr pi])))

(defn escape-field
  "An empty EscapeField sized for tile t."
  [t]
  {:counts (int-array (pixels t)) :mag2 (double-array (pixels t))})

(defn total-iters
  "Sum of the escape counts: the number every renderer reports."
  ^long [{:keys [^ints counts]}]
  (areduce counts i acc 0 (+ acc (aget counts i))))

(defn parse-query
  "Promote a map of query strings into a Tile, defaults filled in. jr and ji
  together select the z-plane (Julia) seed with k = jr + i ji."
  [q]
  (let [num #(if-let [s (get q %1)] (Double/parseDouble s) %2)
        lng #(if-let [s (get q %1)] (Long/parseLong s) %2)]
    (tile (cond-> {:cx (num "cx" -0.6) :cy (num "cy" 0.0) :scale (num "scale" 0.004)
                   :w (lng "w" 640) :h (lng "h" 480) :iter (lng "iter" 256)
                   :formula (get q "formula" formula/default-id)}
            (and (get q "jr") (get q "ji")) (assoc :julia [(num "jr" 0.0) (num "ji" 0.0)])))))
