(ns laws
  "Native runtime laws plus hive-test golden and mutation witnesses.
   Run serially: cljw -M:laws. Source mutation campaigns remain separate."
  (:require [clojure.test :as test]
            [clojure.string :as str]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [hive-test.trifecta :refer [deftrifecta]]
            [hive-test.mutation :refer [deftest-mutation-witness]]
            [hive-test.properties :refer [defprop-metamorphic]]
            [hive-test.golden :refer [deftest-golden]]
            [golden-anchor :as anchor]))

(def int-vectors (gen/vector (gen/choose -1000 1000) 0 30))
(def slices
  (gen/bind int-vectors
    (fn [xs]
      (gen/bind (gen/choose 0 (count xs))
        (fn [start]
          (gen/fmap (fn [end] [xs start end])
                    (gen/choose start (count xs))))))))
(def text-input
  (gen/fmap #(apply str %) (gen/vector (gen/elements [\a \b \space \newline \return]) 0 50)))

(deftrifecta subvec-boundaries
  #'clojure.core/subvec
  {:golden-path "subvec.edn"
   :apply? true
   :cases {:empty [[] 0]
           :suffix [[0 1 2 3] 2]
           :middle [[0 1 2 3] 1 3]
           :empty-middle [[0 1 2 3] 2 2]}
   :gen slices
   :pred vector?
   :num-tests {:num-tests 200 :seed 20260906}
   :mutations [["ignore-start" (fn [xs _ & ends] (vec (take (if (seq ends) (first ends) (count xs)) xs)))]
               ["include-end" (fn [xs start & ends] (vec (take (inc (- (if (seq ends) (first ends) (count xs)) start)) (drop start xs))))]]})

(deftrifecta split-lines-boundaries
  #'clojure.string/split-lines
  {:golden-path "split-lines.edn"
   :cases {:empty "" :plain "alpha" :lf "a\nb\n" :crlf "a\r\nb\r\n"
           :empty-line "a\n\nb" :lone-cr "a\rb"}
   :gen text-input
   :pred vector?
   :num-tests {:num-tests 200 :seed 20260907}
   :mutations [["lf-only" (fn [s] (str/split s #"\n"))]
               ["retain-trailing-empty" (fn [s] (str/split s #"\r?\n" -1))]]})

(deftrifecta replace-boundaries
  #'clojure.string/replace
  {:golden-path "replace.edn"
   :apply? true
   :cases {:repeated ["abaaba" "a" "x"]
           :absent ["bbb" "a" "x"]
           :delete ["abaaba" "a" ""]
           :literal-replacement ["a.a" "a" "$1\\x"]}
   :gen (gen/fmap (fn [s] [s "a" "x"]) text-input)
   :pred string?
   :num-tests {:num-tests 200 :seed 20260908}
   :mutations [["first-only" str/replace-first]
               ["ignore-replacement" (fn [s _ _] s)]]})

(defspec apply-preserves-split-arguments
  {:num-tests 300 :seed 20260909}
  (prop/for-all [xs (gen/vector (gen/choose -1000 1000) 2 30)
                split (gen/choose 0 30)]
    (let [n (min split (count xs))
          f (fn ([a b] [a b]) ([a b & more] (into [a b] more)))]
      (= xs (apply apply f (conj (vec (take n xs)) (drop n xs)))))))

(defspec concat-preserves-order
  {:num-tests 300 :seed 20260910}
  (prop/for-all [left int-vectors right int-vectors]
    (= (into left right) (vec (concat left right)))))

(defspec subvec-conserves-partition
  {:num-tests 300 :seed 20260911}
  (prop/for-all [[xs start end] slices]
    (= xs (into (into (subvec xs 0 start) (subvec xs start end))
                (subvec xs end)))))

(defspec repeat-truncates-positive-count
  {:num-tests 300 :seed 20260912}
  (prop/for-all [n (gen/choose 0 30) x (gen/choose -1000 1000)]
    (= (vec (repeat n x)) (vec (repeat (+ n 0.75) x)))))

(defspec replace-preserves-unmatched-characters
  {:num-tests 300 :seed 20260913}
  (prop/for-all [s text-input]
    (let [out (str/replace s "a" "x")]
      (and (= (count s) (count out))
           (= (count (filter #{\a} s)) (count (filter #{\x} out)))
           (= (remove #{\a} s) (remove #{\x} out))))))

(defspec list-construction-preserves-type-and-values
  {:num-tests 300 :seed 20260914}
  (prop/for-all [xs int-vectors]
    (let [result (apply list xs)]
      (and (list? result) (= xs result) (nil? (meta result))))))

(deftest-mutation-witness list-rest-alias-is-caught
  clojure.core/list
  (fn [& xs] (if xs xs '()))
  (fn []
    (test/is (list? (apply list [1 2 3])))
    (test/is (nil? (meta (apply list (with-meta '(1 2 3) {:source true})))))))

(defn -main [& _]
  ;; Goldens anchor to THIS fixture on both runtimes, and an absent one is a
  ;; failure rather than a capture. Without this, native cljw resolves a golden
  ;; against the working directory (io/resource is nil by D-359) and hive-test
  ;; writes the missing file and passes. `install` resolves the root AND asserts
  ;; the reviewed corpus in one call, so neither check can be skipped.
  ;; See golden_anchor.clj.
  (let [{:keys [root bindings]} (anchor/install)]
    (println "golden root:" root)
    (with-bindings bindings
      (let [{:keys [test pass fail error] :as result} (test/run-tests 'laws)]
        (assert (= 21 test) (pr-str result))
        (assert (and (pos? pass) (zero? fail) (zero? error)) (pr-str result))
        (println "OK native runtime laws: 3000 generated cases, nine mutation witnesses, four goldens")))))

(defprop-metamorphic lazy-string-body-agrees-with-seq
  (fn [value]
    [(seq value) (first value) (rest value) (next value) (count value) (vec value)])
  (fn [text] (lazy-seq text))
  =
  text-input
  {:num-tests {:num-tests 300 :seed 20260915}})

(defspec nested-lazy-seqable-preserves-elements
  {:num-tests 300 :seed 20260916}
  (prop/for-all [xs int-vectors depth (gen/choose 1 30)]
    (let [body (loop [value (reify clojure.lang.Seqable (seq [_] (seq xs)))
                      n depth]
                 (if (zero? n) value (recur (lazy-seq value) (dec n))))]
      (and (= xs (vec body))
           (= (count xs) (count body))
           (= (first xs) (first body))))))

(deftest-mutation-witness lazy-first-must-read-the-body
  clojure.core/first
  (let [original first]
    (fn [value]
      (if (instance? clojure.lang.LazySeq value) nil (original value))))
  (fn []
    (test/is (= \h (first (lazy-seq "hi"))))))

(deftest-mutation-witness lazy-seq-must-return-a-seq
  clojure.core/seq
  (let [original seq]
    (fn [value]
      (if (instance? clojure.lang.LazySeq value) "hi" (original value))))
  (fn []
    (test/is (= '(\h \i) (seq (lazy-seq "hi"))))))

(deftest-golden lazy-seqable-boundaries "lazy-seqable.edn"
  {:string [(seq (lazy-seq "hi")) (first (lazy-seq "hi"))
            (rest (lazy-seq "hi")) (next (lazy-seq "hi")) (count (lazy-seq "hi"))]
   :empty [(seq (lazy-seq "")) (first (lazy-seq "")) (rest (lazy-seq "")) (count (lazy-seq ""))]
   :array (vec (lazy-seq (to-array [1 2])))
   :array-alias (let [a (to-array ["old" "tail"])
                      body (lazy-seq a)
                      before (first body)]
                  (aset a 0 "new")
                  [before (first body) (vec (rest body))])
   :custom (seq (lazy-seq
                  (reify clojure.lang.Seqable (seq [_] (seq [3 4])))))
   :nested (vec (lazy-seq (lazy-seq [5 6])))
   :invalid-body (try (seq (lazy-seq 42))
                      (catch IllegalArgumentException _ :illegal-argument))
   :invalid-seq-result (try (seq (reify clojure.lang.Seqable (seq [_] [1 2])))
                            (catch ClassCastException _ :class-cast))})
