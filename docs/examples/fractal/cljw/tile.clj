;; Domain values on cljw, pure. A Tile is {:cx :cy :scale :w :h :iter};
;; the same shape and limits as the JVM's fractal.tile.
(ns fractal.cljw.tile)

(def max-pixels (* 1024 1024))

(defn finite? [x] (and (number? x) (== 0.0 (- (double x) (double x)))))

(defn problems
  "Why m is not a Tile, or nil when it is one."
  [{:keys [cx cy scale w h iter]}]
  (let [ps (cond-> []
             (not (and (finite? cx) (finite? cy) (finite? scale))) (conj "cx, cy and scale must be finite numbers")
             (and (finite? scale) (not (pos? scale))) (conj "scale must be positive")
             (not (and (int? w) (int? h) (pos? w) (pos? h))) (conj "w and h must be positive integers")
             (and (int? w) (int? h) (> (* w h) max-pixels)) (conj (str "w*h must be at most " max-pixels))
             (not (and (int? iter) (pos? iter))) (conj "iter must be a positive integer"))]
    (when (seq ps) ps)))

(defn tile
  "Validate m into a Tile; throws ex-info naming the first problem."
  [m]
  (if-let [p (problems m)]
    (throw (ex-info (first p) {:problems p}))
    (select-keys m [:cx :cy :scale :w :h :iter])))

(defn parse-query
  "Promote a query-string map into a Tile, defaults filled in."
  [q]
  (let [num (fn [k d] (if-let [s (get q k)] (Double/parseDouble s) d))
        lng (fn [k d] (if-let [s (get q k)] (Long/parseLong s) d))]
    (tile {:cx (num "cx" -0.6) :cy (num "cy" 0.0) :scale (num "scale" 0.004)
           :w (lng "w" 640) :h (lng "h" 480) :iter (lng "iter" 256)})))

(defn query-map
  "Collect: a raw query string into a map of strings."
  [qs]
  (if (nil? qs)
    {}
    (into {} (keep (fn [pair]
                     (let [i (.indexOf pair "=")]
                       (when (pos? i) [(subs pair 0 i) (subs pair (inc i))]))))
          (.split qs "&"))))

(defn checksum
  "The golden checksum of an RGBA8 framebuffer."
  [pixels]
  (reduce (fn [acc b] (mod (+ (* acc 31) (bit-and 255 b)) 2147483647)) 1 pixels))
