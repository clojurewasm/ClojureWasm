(ns fractal.property-test
  "Property-based: on generated tiles, every exact renderer computes the
  oracle's EscapeField bit for bit; the palette and the tile domain keep
  their laws; the HTTP boundary answers the frame it renders."
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check :as tc]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [fractal.engines :as engines]
            [fractal.http :as http]
            [fractal.palette :as palette]
            [fractal.renderer :as r]
            [fractal.renderer.oracle :as oracle]
            [fractal.tile :as tile]))

(def gen-tile
  "Small tiles around the set, from the full view down to deep zoom."
  (gen/let [cx (gen/double* {:min -2.0 :max 0.6 :NaN? false :infinite? false})
            cy (gen/double* {:min -1.2 :max 1.2 :NaN? false :infinite? false})
            zoom (gen/choose 2 40)
            w (gen/choose 1 24)
            h (gen/choose 1 24)
            iter (gen/choose 1 600)]
    (tile/tile {:cx cx :cy cy :scale (/ 3.0 (Math/pow 2.0 (/ zoom 2.0))) :w w :h h :iter iter})))

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
      (check 60 (prop/for-all [t gen-tile]
                  (same-field? (field-of o t) (field-of rr t)))))))

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
                            iter gen/small-integer scale gen/double]
               (let [m {:cx 0.0 :cy 0.0 :scale scale :w w :h h :iter iter}
                     ok? (and (pos? w) (pos? h) (pos? iter) (Double/isFinite scale) (pos? scale))]
                 (= ok? (nil? (tile/problems m)))))))

(deftest http-tile-answers-the-frame
  (let [rr (oracle/renderer)
        registry (r/registry [rr])]
    (check 40 (prop/for-all [t gen-tile]
                (let [q (into {"engine" "clojure-jvm"} (map (fn [[k v]] [(name k) (str v)])) t)
                      {:keys [status headers body]} (http/respond registry [] {:path "/tile" :query q})
                      f (r/frame rr t)]
                  (and (= 200 status)
                       (= (str (:iters f)) (get headers "x-iters"))
                       (java.util.Arrays/equals ^bytes body ^bytes (:rgba f))))))))
