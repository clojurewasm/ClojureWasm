(ns fractal.formula
  "Domain: the escape-time formulas, as data. A Formula is one step of the
  orbit, z <- f(z, c), written in a small expression language over the
  doubles zr zi cr ci:

    (+ a b) (- a b) (* a b) (abs a), number literals, and symbols bound by
    the step's :let pairs (evaluated in order, from the OLD z).

  The step is data, not code, so every backend compiles the SAME expression
  (the oracle to a Clojure fn, raster to a typed deftm, CUDA to C) and they
  agree to the last bit: each operation is written once, in one order, and
  fp64 without FMA rounds it the same way everywhere. Adding a formula is
  adding one entry to `registry`; the mutation suite derives its mutants from
  the expression.

  A Seed says where the orbit starts: :c-plane (z0 = 0, c = pixel, the
  Mandelbrot-style set) or :z-plane (z0 = pixel, c = k, the Julia set of the
  same formula). Seed and formula are independent axes.")

(def ops
  "Operator symbol of the expression language -> the Clojure form it lowers to."
  {'+ 'clojure.core/+ '- 'clojure.core/- '* 'clojure.core/* 'abs 'Math/abs})

(def arity {'+ 2 '- 2 '* 2 'abs 1})

(def inputs '#{zr zi cr ci})

(def registry
  "Formula id -> Formula, in display order. :home is the c-plane view that
  frames the set; :julia-k is a k whose Julia set is worth opening on."
  (array-map
   "mandelbrot"
   {:id "mandelbrot" :what "z^2 + c"
    :step {:let [] :zr '(+ (- (* zr zr) (* zi zi)) cr) :zi '(+ (* (* 2.0 zr) zi) ci)}
    :home {:cx -0.5 :cy 0.0 :scale 0.0068359375}
    :julia-k [-0.8 0.156]}

   "burning-ship"
   {:id "burning-ship" :what "(|Re z| + i|Im z|)^2 + c"
    :step {:let [] :zr '(+ (- (* zr zr) (* zi zi)) cr) :zi '(+ (* (* 2.0 (abs zr)) (abs zi)) ci)}
    :home {:cx -0.45 :cy -0.5 :scale 0.0055}
    :julia-k [-1.2 0.0]}

   "tricorn"
   {:id "tricorn" :what "conj(z)^2 + c"
    :step {:let [] :zr '(+ (- (* zr zr) (* zi zi)) cr) :zi '(+ (* (* -2.0 zr) zi) ci)}
    :home {:cx -0.3 :cy 0.0 :scale 0.0068359375}
    :julia-k [-0.4 0.3]}

   "multibrot3"
   {:id "multibrot3" :what "z^3 + c"
    :step {:let '[zr2 (* zr zr) zi2 (* zi zi)]
           :zr '(+ (* zr (- zr2 (* 3.0 zi2))) cr)
           :zi '(+ (* zi (- (* 3.0 zr2) zi2)) ci)}
    :home {:cx 0.0 :cy 0.0 :scale 0.0055}
    :julia-k [-0.2 0.75]}))

(def default-id "mandelbrot")

(defn known? [id] (contains? registry id))

(defn ids [] (vec (keys registry)))

(defn formula
  "The Formula for id; throws ex-info for an unknown id."
  [id]
  (or (get registry id)
      (throw (ex-info (str "unknown formula " id) {:formula id :known (ids)}))))

;; --- the expression language ------------------------------------------------

(defn expr-problems
  "Why expr is not an expression over the symbols in scope, or nil."
  [scope expr]
  (cond
    (number? expr) nil
    (symbol? expr) (when-not (contains? scope expr) [(str "unbound symbol " expr)])
    (seq? expr) (let [[op & args] expr]
                  (cond
                    (not (contains? ops op)) [(str "unknown operator " op)]
                    (not= (arity op) (count args)) [(str op " takes " (arity op) " arguments")]
                    :else (not-empty (vec (mapcat #(expr-problems scope %) args)))))
    :else [(str "not an expression: " (pr-str expr))]))

(defn step-problems
  "Why step is not a well-formed step, or nil."
  [{lets :let :keys [zr zi] :as step}]
  (if-not (and (map? step) (vector? lets) (even? (count lets)) zr zi)
    ["a step is {:let [sym expr ...] :zr expr :zi expr}"]
    (let [[scope ps] (reduce (fn [[scope ps] [s e]]
                               [(conj scope s)
                                (cond-> (into ps (expr-problems scope e))
                                  (not (symbol? s)) (conj (str "let binds a non-symbol " (pr-str s)))
                                  (contains? inputs s) (conj (str "let shadows input " s)))])
                             [inputs []]
                             (partition 2 lets))]
      (not-empty (into ps (concat (expr-problems scope zr) (expr-problems scope zi)))))))

(defn lower
  "The expression as a Clojure form, operators qualified, literals double."
  [expr]
  (cond
    (seq? expr) (let [[op & args] expr] (apply list (ops op) (map lower args)))
    (number? expr) (double expr)
    :else expr))

(defn step-form
  "The step as a Clojure form over zr zi cr ci: the :let bindings, then the
  call `(~@k zr' zi')`. k is the head of that call: `[vector]` builds a pair
  in a fn body, `[recur (inc n)]` continues a loop."
  [{lets :let :keys [zr zi]} k]
  (list 'clojure.core/let (vec (mapcat (fn [[s e]] [s (lower e)]) (partition 2 lets)))
        (concat k [(lower zr) (lower zi)])))
