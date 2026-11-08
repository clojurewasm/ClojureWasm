(ns fractal.golden-test
  "Golden: every exact renderer this JVM can run reproduces golden.edn, the
  numbers cljw's wasm kernels produced. A renderer that is unavailable here
  (no GPU) is reported, not failed."
  (:require [clojure.test :refer [deftest is testing]]
            [fractal.bench :as bench]
            [fractal.engines :as engines]
            [fractal.golden :as golden]
            [fractal.palette :as palette]
            [fractal.renderer :as r]))

(def found (delay (engines/discover)))

(deftest every-exact-renderer-reproduces-golden
  (let [{:keys [renderers unavailable]} @found]
    (doseq [{:keys [id reason]} unavailable]
      (println "golden-test: renderer unavailable here:" id "-" reason))
    (is (seq renderers) "at least the CPU renderers are available")
    (doseq [rr renderers
            :when (:parity? (r/describe rr))
            v (golden/load-views)
            :when (bench/runs? rr v)]
      (testing (str (r/id rr) " on " (:name v))
        (let [f (r/frame rr (golden/view->tile v))]
          (is (nil? (golden/verdict v (:iters f) (palette/checksum (:rgba f))))))))))

(deftest golden-file-is-well-formed
  (doseq [v (golden/load-views)]
    (is (golden/view->tile v) (:name v))
    (is (pos-int? (:iters v)))
    (is (nat-int? (:checksum v)))))
