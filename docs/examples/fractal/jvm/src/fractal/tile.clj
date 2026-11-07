(ns fractal.tile
  "Domain values. A Tile is the question: {:cx :cy :scale :w :h :iter}, pixel
  (x, y) being the point (cx + (x - w/2) scale, cy + (y - h/2) scale). An
  EscapeField is the answer every renderer gives: per pixel the escape count
  (ints) and |z|^2 at escape (doubles). Pure functions only.")

(def max-pixels (* 1024 1024))

(def max-iter (dec (bit-shift-left 1 26)))

(defn finite? [x] (and (number? x) (Double/isFinite (double x))))

(defn problems
  "Why m is not a Tile, or nil when it is one."
  [{:keys [cx cy scale w h iter]}]
  (not-empty
   (cond-> []
     (not (every? finite? [cx cy scale])) (conj "cx, cy and scale must be finite numbers")
     (and (finite? scale) (not (pos? scale))) (conj "scale must be positive")
     (not (and (int? w) (int? h) (pos? w) (pos? h))) (conj "w and h must be positive integers")
     (and (int? w) (int? h) (> (* w h) max-pixels)) (conj (str "w*h must be at most " max-pixels))
     (not (and (int? iter) (pos? iter))) (conj "iter must be a positive integer"))))

(defn tile
  "Validate and normalise m into a Tile; throws ex-info listing the problems."
  [m]
  (if-let [p (problems m)]
    (throw (ex-info (first p) {:tile m :problems p}))
    (-> (select-keys m [:cx :cy :scale :w :h :iter])
        (update :cx double) (update :cy double) (update :scale double)
        (update :iter #(min % max-iter)))))

(defn pixels [{:keys [w h]}] (* w h))

(defn point
  "The complex point of pixel (x, y): [re im]."
  [{:keys [cx cy scale w h]} x y]
  [(+ cx (* (- (double x) (/ (double w) 2.0)) scale))
   (+ cy (* (- (double y) (/ (double h) 2.0)) scale))])

(defn escape-field
  "An empty EscapeField sized for tile t."
  [t]
  {:counts (int-array (pixels t)) :mag2 (double-array (pixels t))})

(defn total-iters
  "Sum of the escape counts: the number every renderer reports."
  ^long [{:keys [^ints counts]}]
  (areduce counts i acc 0 (+ acc (aget counts i))))

(defn parse-query
  "Promote a map of query strings into a Tile, defaults filled in."
  [q]
  (let [num #(if-let [s (get q %1)] (Double/parseDouble s) %2)
        lng #(if-let [s (get q %1)] (Long/parseLong s) %2)]
    (tile {:cx (num "cx" -0.6) :cy (num "cy" 0.0) :scale (num "scale" 0.004)
           :w (lng "w" 640) :h (lng "h" 480) :iter (lng "iter" 256)})))
