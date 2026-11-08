(ns fractal.property-test
  "Property-based: on generated tiles, every exact renderer computes the
  oracle's EscapeField bit for bit; the palette and the tile domain keep
  their laws; the HTTP boundary answers the frame it renders."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check :as tc]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [fractal.engines :as engines]
            [fractal.http :as http]
            [fractal.palette :as palette]
            [fractal.renderer :as r]
            [fractal.renderer.oracle :as oracle]
            [fractal.tile :as tile]
            [fractal.formula :as formula]))

(def gen-tile
  "Small tiles of every formula on both seeds, from the full view down to
  deep zoom."
  (gen/let [formula (gen/elements (formula/ids))
            julia (gen/one-of [(gen/return nil)
                               (gen/tuple (gen/double* {:min -1.5 :max 1.5 :NaN? false})
                                          (gen/double* {:min -1.5 :max 1.5 :NaN? false}))])
            cx (gen/double* {:min -2.0 :max 0.6 :NaN? false :infinite? false})
            cy (gen/double* {:min -1.2 :max 1.2 :NaN? false :infinite? false})
            zoom (gen/choose 2 40)
            w (gen/choose 1 24)
            h (gen/choose 1 24)
            iter (gen/choose 1 600)]
    (tile/tile (cond-> {:cx cx :cy cy :scale (/ 3.0 (Math/pow 2.0 (/ zoom 2.0))) :w w :h h :iter iter
                        :formula formula}
                 julia (assoc :julia julia)))))

(def exact-renderers
  (delay (filterv #(and (:parity? (r/describe %)) (not= "clojure-jvm" (r/id %)))
                  (:renderers (engines/discover)))))

(defn- field-of [rr t] (let [f (tile/escape-field t)] (r/escape! rr t f) f))

(defn- same-field? [a b]
  (and (java.util.Arrays/equals ^ints (:counts a) ^ints (:counts b))
       (java.util.Arrays/equals ^doubles (:mag2 a) ^doubles (:mag2 b))))

(defn- check [n p]
  (let [res (tc/quick-check n p)]
    (is (:pass? res) (pr-str (select-keys res [:fail :shrunk :seed])))))

(deftest every-exact-renderer-equals-the-oracle
  (let [o (oracle/renderer)]
    (doseq [rr @exact-renderers]
      (testing (r/id rr)
        (check 80 (prop/for-all [t gen-tile]
                    (or (not (r/renders? rr t))
                        (same-field? (field-of o t) (field-of rr t)))))))))

(deftest the-winners-render-every-formula-on-both-seeds
  (doseq [rr @exact-renderers
          :when (#{"raster-jvm" "raster-jvm-1t" "cuda-f64"} (r/id rr))]
    (is (= (set (formula/ids)) (r/formulas rr)) (r/id rr))
    (is (:julia? (r/describe rr)) (r/id rr))))

(deftest escape-counts-are-bounded
  (check 200 (prop/for-all [t gen-tile]
               (let [{:keys [^ints counts]} (field-of (oracle/renderer) t)]
                 (every? #(<= 0 % (:iter t)) counts)))))

(deftest palette-laws
  (check 500 (prop/for-all [n (gen/choose 0 5000)
                            limit (gen/choose 1 5000)
                            mag2 (gen/double* {:min 0.0 :NaN? false})]
               (let [n (min n limit)
                     [rr g b a] (palette/rgba n limit mag2)]
                 (and (= 255 a)
                      (every? #(<= 0 % 255) [rr g b])
                      (= (== n limit) (= [0 0 0] [rr g b])))))))

(deftest paint-is-rgba-per-pixel
  (check 60 (prop/for-all [t gen-tile]
              (let [f (field-of (oracle/renderer) t)
                    bytes (palette/paint f t)
                    p (rand-int (tile/pixels t))]
                (= (palette/rgba (aget ^ints (:counts f) p) (:iter t) (aget ^doubles (:mag2 f) p))
                   (mapv #(bit-and 255 (aget ^bytes bytes (+ (* 4 p) %))) (range 4)))))))

(deftest tile-validation
  (check 300 (prop/for-all [w gen/small-integer h gen/small-integer
                            iter gen/small-integer scale gen/double
                            formula (gen/one-of [(gen/elements (formula/ids)) gen/string-alphanumeric])
                            julia (gen/one-of [(gen/return nil) (gen/vector gen/double 0 3)])]
               (let [m (cond-> {:cx 0.0 :cy 0.0 :scale scale :w w :h h :iter iter :formula formula}
                         julia (assoc :julia julia))
                     ok? (and (pos? w) (pos? h) (pos? iter) (Double/isFinite scale) (pos? scale)
                              (formula/known? formula)
                              (or (nil? julia) (and (= 2 (count julia)) (every? #(Double/isFinite %) julia))))]
                 (= ok? (nil? (tile/problems m)))))))

(defn- query-of
  "The /tile query string map that asks for tile t on engine rid."
  [rid t]
  (cond-> (into {"engine" rid}
                (map (fn [k] [(name k) (str (get t k))]))
                [:cx :cy :scale :w :h :iter :formula])
    (:julia t) (assoc "jr" (str (first (:julia t))) "ji" (str (second (:julia t))))))

(deftest http-tile-answers-the-frame
  (let [rr (oracle/renderer)
        registry (r/registry [rr])]
    (check 40 (prop/for-all [t gen-tile]
                (let [{:keys [status headers body]} (http/respond registry [] {:path "/tile" :query (query-of "clojure-jvm" t)})
                      f (r/frame rr t)]
                  (and (= 200 status)
                       (= (str (:iters f)) (get headers "x-iters"))
                       (java.util.Arrays/equals ^bytes body ^bytes (:rgba f))))))))

;; A renderer that names no formulas: the port's default, Mandelbrot on the
;; c-plane only. It paints nothing, so a 200 for any other tile is a leak.
(def ^:private mandelbrot-only
  (reify r/IRenderer
    (id [_] "mandelbrot-only")
    (describe [_] {:parity? true :heavy? false :what "stub"})
    (escape! [_ _ field] field)))

(deftest http-refuses-what-an-engine-does-not-render
  (let [registry (r/registry [mandelbrot-only])]
    (check 100 (prop/for-all [t gen-tile]
                 (let [{:keys [status]} (http/respond registry [] {:path "/tile" :query (query-of "mandelbrot-only" t)})]
                   (= status (if (and (= "mandelbrot" (:formula t)) (nil? (:julia t))) 200 400)))))))
