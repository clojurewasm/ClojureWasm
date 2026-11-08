;; D-346: collection literals, constant and evaluated, at every size.
;; JVM oracle (clojure -M -e, 2026-09-27): a literal whose elements are all
;; constants is ONE constant (Compiler ConstantExpr), so the same literal
;; evaluated twice is identical?; a literal with an evaluated element or with
;; reader metadata is rebuilt on every evaluation. The JVM rejects the 40k
;; literals below with "Method code too large!"; cljw builds them.
(ns suites.bulk-literal-test
  (:require [clojure.test :refer [deftest is testing]]))

(defn- ints [n] (apply str (interpose " " (range n))))

(defn- ev [s] (eval (read-string s)))

(deftest constant-literals-are-one-constant
  (let [v (fn [] [1 2]) m (fn [] {:a 1}) s (fn [] #{1 2})
        big-map (fn [] {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18})]
    (is (identical? (v) (v)))
    (is (identical? (m) (m)))
    (is (identical? (s) (s)))
    (is (identical? (big-map) (big-map)))
    (is (instance? clojure.lang.PersistentHashMap (big-map))))
  (testing "nested constants and quoted elements fold with their parent"
    (let [f (fn [] [(quote a) :k "s" \c 1.5 nil true 3N 1/2 [1 [2]] #{:x} {:y 1}])]
      (is (identical? (f) (f)))
      (is (= '[a :k "s" \c 1.5 nil true 3N 1/2 [1 [2]] #{:x} {:y 1}] (f)))))
  (testing "a constant nested in an evaluated literal is still one constant"
    (let [f (fn [x] {:a [1 2] :b x})]
      (is (identical? (:a (f 1)) (:a (f 2))))
      (is (not (identical? (f 1) (f 1))))))
  (testing "evaluated elements and reader metadata rebuild the literal"
    (let [d (fn [x] [x 2]) mv (fn [] ^:m [1 2])]
      (is (not (identical? (d 1) (d 1))))
      (is (not (identical? (mv) (mv))))
      (is (= {:m true} (meta (mv))))
      (is (nil? (meta ((fn [] [1 2])))))))
  (testing "array-map order survives the fold"
    (is (= [:z :y :x :w] (keys ((fn [] {:z 1 :y 2 :x 3 :w 4})))))))

(deftest chunk-boundaries-preserve-order
  ;; Evaluated elements on both sides of every 512-element build step.
  (let [n 1100
        at #{0 510 511 512 513 1023 1024 1025 1099}
        src (str "(fn [x] [" (apply str (interpose " " (map #(if (at %) (str "(+ x " % ")") (str %)) (range n)))) "])")
        f (ev src)]
    (is (= (vec (range n)) (f 0)))
    (is (= 1100 (count (f 1)))))
  (let [n 1100
        src (str "(fn [x] {" (apply str (interpose " " (map #(str % " " (if (odd? %) "x" %)) (range n)))) "})")
        m ((ev src) :v)]
    (is (= n (count m)))
    (is (= :v (get m 511)))
    (is (= 512 (get m 512)))
    (is (= :v (get m 1099))))
  (let [src (str "(fn [x] #{" (ints 1100) " x})")
        s ((ev src) 5000)]
    (is (= 1101 (count s)))
    (is (contains? s 5000))
    (is (contains? s 1099))))

(deftest forty-thousand-element-literals
  (let [n 40000]
    (testing "constant literals, through read-string and eval"
      (is (= n (count (ev (str "[" (ints n) "]")))))
      (is (= 39999 (nth (ev (str "[" (ints n) "]")) 39999)))
      (let [m (ev (str "{" (apply str (interpose " " (map #(str % " " (inc %)) (range n)))) "}"))]
        (is (= n (count m)))
        (is (= 40000 (get m 39999))))
      (let [s (ev (str "#{" (ints n) "}"))]
        (is (= n (count s)))
        (is (contains? s 39999))))
    (testing "evaluated literals build in bounded steps"
      (let [f (ev (str "(fn [x] [" (apply str (repeat n "x ")) "])"))]
        (is (= (repeat n 3) (f 3))))
      (let [f (ev (str "(fn [x] {" (apply str (map #(str % " x ") (range n))) "})"))
            m (f :v)]
        (is (= n (count m)))
        (is (= :v (get m 0) (get m 39999))))
      (let [f (ev (str "(fn [x] #{x " (ints (dec n)) "})"))
            s (f -1)]
        (is (= n (count s)))
        (is (contains? s -1))))
    (testing "nested evaluated literals"
      (let [f (ev (str "(fn [x] [0 {:v [" (apply str (repeat n "x ")) "]} x])"))
            r (f 9)]
        (is (= 9 (nth r 2)))
        (is (= n (count (:v (nth r 1)))))))))
