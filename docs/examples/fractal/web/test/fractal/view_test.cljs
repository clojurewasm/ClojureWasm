(ns fractal.view-test
  "Property-based laws of the view value: zooming keeps the point under the
  cursor, panning is reversible, the URL hash round-trips, and split panes
  tile the shared view without a seam."
  (:require [cljs.test :refer [deftest is]]
            [clojure.test.check :as tc]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [fractal.view :as view]
            [fractal.engines :as engines]
            [fractal.events :as ev]))

(def gen-view
  (gen/let [cx (gen/double* {:min -2.0 :max 1.0 :NaN? false :infinite? false})
            cy (gen/double* {:min -1.5 :max 1.5 :NaN? false :infinite? false})
            e (gen/choose 1 40)]
    {:cx cx :cy cy :scale (js/Math.pow 2 (- e))}))

(def gen-canvas (gen/tuple (gen/choose 8 1024) (gen/choose 8 1024)))

(defn- close? [a b tol] (<= (js/Math.abs (- a b)) (* tol (max 1 (js/Math.abs a) (js/Math.abs b)))))

(def ^:private plane-point view/plane-point)

(defn- check [n p]
  (let [r (tc/quick-check n p)]
    (is (:pass? r) (pr-str (select-keys r [:shrunk :seed])))))

(deftest zoom-keeps-the-cursor-point
  (check 300 (prop/for-all [v gen-view [w h] gen-canvas
                            fx (gen/double* {:min 0 :max 1 :NaN? false})
                            fy (gen/double* {:min 0 :max 1 :NaN? false})
                            factor (gen/elements [0.5 1.5 2 4 0.25])]
               (let [px (* fx w) py (* fy h)
                     before (plane-point v [w h] [px py])
                     after (plane-point (view/zoom-at v [w h] [px py] factor) [w h] [px py])]
                 (and (close? (first before) (first after) 1e-9)
                      (close? (second before) (second after) 1e-9))))))

(deftest zoom-scales-by-the-factor
  (check 200 (prop/for-all [v gen-view c gen-canvas factor (gen/elements [0.5 2 4])]
               (close? (/ (:scale v) factor) (:scale (view/zoom-at v c [0 0] factor)) 1e-12))))

(deftest pan-is-reversible
  (check 300 (prop/for-all [v gen-view dx (gen/choose -500 500) dy (gen/choose -500 500)]
               (let [back (view/pan (view/pan v [dx dy]) [(- dx) (- dy)])]
                 (and (close? (:cx v) (:cx back) 1e-9) (close? (:cy v) (:cy back) 1e-9))))))

(def gen-fractal
  (gen/let [formula (gen/elements ["mandelbrot" "burning-ship" "tricorn" "multibrot3"])
            julia (gen/one-of [(gen/return nil)
                               (gen/tuple (gen/double* {:min -2 :max 2 :NaN? false})
                                          (gen/double* {:min -2 :max 2 :NaN? false}))])]
    {:formula formula :julia julia}))

(deftest hash-round-trips
  (check 300 (prop/for-all [v gen-view iter (gen/choose 1 4096) f gen-fractal]
               (= (cond-> {:view v :iter iter}
                    (not= f view/default-fractal) (assoc :fractal f))
                  (view/<-hash (view/->hash v iter f))))))

(deftest a-mandelbrot-hash-is-unchanged
  (check 100 (prop/for-all [v gen-view iter (gen/choose 1 4096)]
               (= (view/->hash v iter) (view/->hash v iter view/default-fractal)))))

(deftest hash-ignores-garbage
  (is (= {:view {}} (view/<-hash "#cx=abc&scale=-1&iter=")))
  (is (= {:view {}} (view/<-hash nil))))

(deftest split-panes-tile-the-view
  (check 200 (prop/for-all [v gen-view [w h] gen-canvas]
               (let [lw (js/Math.floor (/ w 2))
                     left (view/pane-view v [w h] [0 lw] 1)
                     right (view/pane-view v [w h] [lw (- w lw)] 1)
                     ;; the plane x of the left pane's last column + 1 is the right pane's first
                     left-edge (+ (:cx left) (* (- lw (/ (:w left) 2)) (:scale left)))
                     right-edge (+ (:cx right) (* (- 0 (/ (:w right) 2)) (:scale right)))]
                 (and (= (+ (:w left) (:w right)) w)
                      (close? left-edge right-edge 1e-9))))))

;; --- the fractal and the engines that may draw it --------------------------------

(def engine-ids ["browser-zig" "browser-js" "server-zig-jit" "raster-jvm" "cuda-f64" "cuda-f32"])

(def gen-caps
  "Each engine Mandelbrot-only or a random subset of the formulas, with or
  without Julia."
  (gen/fmap #(zipmap engine-ids %)
            (gen/vector (gen/one-of [(gen/return engines/mandelbrot-only)
                                     (gen/let [fs (gen/set (gen/elements ["burning-ship" "tricorn" "multibrot3"]))
                                               j gen/boolean]
                                       {:formulas (conj fs "mandelbrot") :julia? j})])
                        (count engine-ids))))

(deftest fit-engines-picks-only-engines-that-render
  (check 300 (prop/for-all [caps gen-caps f gen-fractal
                            left (gen/elements engine-ids) right (gen/elements engine-ids)]
               (let [db {:engines engine-ids :caps caps :fractal f :left left :right right}
                     ok (set (ev/usable db))
                     fit (ev/fit-engines db)]
                 (and (= ok (set (filter #(engines/caps-render? (caps %) f) engine-ids)))
                      (if (empty? ok)
                        (and (nil? (:left fit)) (nil? (:right fit)))
                        (and (ok (:left fit)) (ok (:right fit))
                             (or (not (ok left)) (= left (:left fit)))
                             (or (not (ok right)) (= right (:right fit))))))))))

(deftest mandelbrot-only-renders-plain-mandelbrot-only
  (check 200 (prop/for-all [f gen-fractal]
               (= (engines/caps-render? engines/mandelbrot-only f)
                  (= f view/default-fractal)))))

(deftest a-plain-mandelbrot-tile-query-names-no-formula
  (check 200 (prop/for-all [v gen-view f gen-fractal]
               (let [q (engines/tile-query (merge v {:w 8 :h 8} f) 64 "e")]
                 (and (= (.has q "formula") (not= "mandelbrot" (:formula f)))
                      (= (.has q "jr") (some? (:julia f))))))))

(deftest julia-k-is-the-point-under-the-cursor
  (check 200 (prop/for-all [v gen-view [w h] gen-canvas
                            fx (gen/double* {:min 0 :max 1 :NaN? false})
                            fy (gen/double* {:min 0 :max 1 :NaN? false})]
               (let [px (* fx w) py (* fy h)
                     db (assoc ev/initial-db :view v :canvas [w h]
                               :engines engine-ids :caps (zipmap engine-ids (repeat {:formulas #{"mandelbrot"} :julia? true})))
                     {db' :db} ((fn [db] (let [[kr ki] (plane-point v [w h] [px py])]
                                           {:db (ev/with-fractal db {:formula "mandelbrot" :julia [kr ki]})})) db)]
                 (and (= (plane-point v [w h] [px py]) (:julia (:fractal db')))
                      (zero? (:cx (:view db'))) (zero? (:cy (:view db'))))))))
