(ns fractal.formula-test
  "The formula domain. Every registry entry is well formed and has golden
  views on both seeds; every backend compiles every entry; the compiled step
  is the expression, bit for bit; and the maths a formula promises holds on
  the oracle (exact symmetries, the unit-disk Julia set)."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check :as tc]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [fractal.formula :as formula]
            [fractal.golden :as golden]
            [fractal.renderer.cuda-source :as cuda-src]
            [fractal.renderer.oracle :as oracle]
            [fractal.renderer.raster :as raster]))

(defn- check [n p]
  (let [res (tc/quick-check n p)]
    (is (:pass? res) (pr-str (select-keys res [:fail :shrunk :seed])))))

(defn- same-double? [a b] (= (Double/doubleToLongBits a) (Double/doubleToLongBits b)))

;; --- the registry -----------------------------------------------------------------

(deftest every-formula-is-well-formed
  (doseq [[id f] formula/registry]
    (testing id
      (is (= id (:id f)))
      (is (nil? (formula/step-problems (:step f))))
      (is (every? number? (map (:home f) [:cx :cy :scale])))
      (is (and (= 2 (count (:julia-k f))) (every? number? (:julia-k f)))))))

(deftest every-formula-has-golden-views-on-both-seeds
  (let [views (golden/load-views)
        of? (fn [id julia?] (some #(and (= id (:formula % formula/default-id))
                                        (= julia? (some? (:julia %))))
                                  views))]
    (doseq [id (formula/ids)]
      (is (of? id false) (str id ": no c-plane golden view"))
      (is (of? id true) (str id ": no Julia golden view")))))

(deftest every-backend-compiles-every-formula
  (let [want (set (for [id (formula/ids) seed [:c-plane :z-plane]] [id seed]))]
    (is (= want (set (keys raster/kernels))))
    (is (= want (set (map (fn [[id seed _]] [id seed]) (keys (cuda-src/kernels))))))
    (is (= (set (formula/ids)) (set (keys (oracle/steps)))))))

(deftest the-cuda-program-has-every-kernel
  (let [src (cuda-src/program)]
    (doseq [k (vals (cuda-src/kernels))]
      (is (re-find (re-pattern (str "void " k "\\(")) src) k))
    (is (= (count (re-seq #"\(" src)) (count (re-seq #"\)" src))))))

;; --- the expression language ------------------------------------------------------

(deftest the-checker-names-what-it-cannot-compile
  (is (formula/step-problems {:let [] :zr '(pow zr 2) :zi 'zi}) "unknown operator")
  (is (formula/step-problems {:let [] :zr '(+ zr) :zi 'zi}) "arity")
  (is (formula/step-problems {:let [] :zr 'w :zi 'zi}) "unbound symbol")
  (is (formula/step-problems {:let '[zr (* zr zr)] :zr 'zr :zi 'zi}) "shadowed input")
  (is (formula/step-problems {:zr 'zr :zi 'zi}) "no :let")
  (is (nil? (formula/step-problems {:let '[a (* zr zr)] :zr '(+ a cr) :zi '(abs ci)}))))

(def gen-expr
  "Expressions of the language over the four inputs."
  (gen/recursive-gen
   (fn [inner]
     (gen/one-of [(gen/fmap (fn [[op a b]] (list op a b)) (gen/tuple (gen/elements '[+ - *]) inner inner))
                  (gen/fmap #(list 'abs %) inner)]))
   (gen/one-of [(gen/elements '[zr zi cr ci])
                (gen/double* {:min -4.0 :max 4.0 :NaN? false :infinite? false})])))

(defn- interp
  "An independent reading of the language: evaluate e in env, no compiler."
  [env e]
  (cond
    (number? e) (double e)
    (symbol? e) (env e)
    :else (let [[op & args] e
                [a b] (map #(interp env %) args)]
            (case op + (+ a b) - (- a b) * (* a b) abs (Math/abs (double a))))))

(def gen-input (gen/double* {:min -3.0 :max 3.0 :NaN? false :infinite? false}))

(deftest every-generated-expression-is-well-formed
  (check 300 (prop/for-all [a gen-expr b gen-expr]
               (nil? (formula/step-problems {:let [] :zr a :zi b})))))

(deftest the-compiled-step-is-the-expression
  (check 200 (prop/for-all [a gen-expr b gen-expr zr gen-input zi gen-input cr gen-input ci gen-input]
               (let [env {'zr zr 'zi zi 'cr cr 'ci ci}
                     [zr' zi'] ((oracle/step-fn {:step {:let [] :zr a :zi b}}) zr zi cr ci)]
                 (and (same-double? zr' (interp env a)) (same-double? zi' (interp env b)))))))

;; --- the maths --------------------------------------------------------------------

(def symmetries
  "Exact symmetries of the c-plane sets: negating a component of z is exact in
  IEEE arithmetic, so these hold bit for bit, not just to rounding."
  {"mandelbrot" [:conj] "tricorn" [:conj] "multibrot3" [:conj :odd]})

(deftest symmetric-formulas-are-exactly-symmetric
  (let [steps (oracle/steps)]
    (doseq [[id syms] symmetries sym syms]
      (testing (str id " " sym)
        (check 200 (prop/for-all [cr (gen/double* {:min -2.0 :max 2.0 :NaN? false})
                                  ci (gen/double* {:min -2.0 :max 2.0 :NaN? false})
                                  limit (gen/choose 1 400)]
                     (let [orb #(oracle/orbit (steps id) 0.0 0.0 %1 %2 limit)]
                       (= (orb cr ci)
                          (case sym :conj (orb cr (- ci)) :odd (orb (- cr) (- ci)))))))))))

(deftest julia-of-z2-at-k-zero-is-the-unit-disk
  (let [step ((oracle/steps) "mandelbrot")]
    (check 300 (prop/for-all [zr gen-input zi gen-input limit (gen/choose 8 300)]
                 (let [m (+ (* zr zr) (* zi zi))
                       [n] (oracle/orbit step zr zi 0.0 0.0 limit)]
                   (cond (<= m 0.81) (= n limit)
                         (>= m 1.21) (< n limit)
                         :else true))))))
