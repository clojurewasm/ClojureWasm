;; CLJW-GC-HEAP-RETURN: the collector reuses freed cell space and hands empty
;; pages back to the OS. `(.totalMemory r)` reports the committed cell heap
;; (mapped GC pages plus live large cells), so both halves are observable from
;; Clojure without reading RSS, which is host noise. The RSS probe lives in
;; bench/gc_heap_return.clj.
(ns suites.gc-heap-return-test
  (:require [clojure.test :refer [deftest is testing]]))

(def ^:private mb (* 1024 1024))

(defn- committed [] (.totalMemory (Runtime/getRuntime)))

(defn- burst
  "Allocate a ~34 MB vector trie (4M elements) and drop it. It must be much
  larger than the free space earlier suites leave in partly used pages of the
  shared run_suites image, or it lands in already-committed pages and the
  growth is invisible (#80's macOS gate: base 208 MB, burst +0.8 MB)."
  []
  (count (vec (range 4000000))))

(deftest requested-collect-returns-empty-pages
  (System/gc)
  (let [base (committed)
        _ (burst)
        grown (committed)
        _ (System/gc)
        after (committed)]
    (testing "the burst grew the committed heap"
      (is (> grown (+ base (* 16 mb)))))
    (testing "System/gc gave the dropped burst's pages back"
      (is (< after (- grown (* 16 mb))))
      (is (<= after (+ base (* 2 mb)))))))

(deftest freed-pages-are-reused-by-the-next-burst
  (System/gc)
  (burst)
  (let [first-peak (committed)]
    (dotimes [_ 4]
      (burst))
    (testing "bursts of one size after a collect refill the same pages"
      (System/gc)
      (burst)
      (is (<= (committed) (+ first-peak (* 2 mb)))))))

(deftest memory-readings-stay-coherent
  (let [r (Runtime/getRuntime)
        t (.totalMemory r)
        f (.freeMemory r)]
    (is (pos? t))
    (is (<= 0 f t))))
