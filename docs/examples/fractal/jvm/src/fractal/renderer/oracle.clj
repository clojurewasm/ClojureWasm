(ns fractal.renderer.oracle
  "The reference renderer: the escape-time definition in plain Clojure, one
  pixel at a time, no library. Every other renderer is tested against it."
  (:require [fractal.renderer :as r]
            [fractal.tile :as tile]))

(defn escape
  "[n mag2] for the point (cr, ci): iterate z <- z^2 + c from 0 while
  n < limit and |z|^2 <= 4. The operation order is the kernels' exactly."
  [cr ci limit]
  (loop [n 0 zr 0.0 zi 0.0]
    (if (and (< n limit) (<= (+ (* zr zr) (* zi zi)) 4.0))
      (recur (inc n) (+ (- (* zr zr) (* zi zi)) cr) (+ (* (* 2.0 zr) zi) ci))
      [n (+ (* zr zr) (* zi zi))])))

(defn fill!
  "Fill field for tile t with the escape rule esc (default `escape`); returns field."
  ([t field] (fill! escape t field))
  ([esc t {:keys [^ints counts ^doubles mag2] :as field}]
   (let [{:keys [w h iter]} t]
     (dotimes [y h]
       (dotimes [x w]
         (let [[cr ci] (tile/point t x y)
               [n m] (esc cr ci iter)
               p (+ (* y w) x)]
           (aset counts p (int n))
           (aset mag2 p (double m)))))
     field)))

;; esc is the escape rule as a value: the reference passes `escape`, the
;; mutation suite passes deliberately broken rules.
(defrecord Oracle [rid esc]
  r/IRenderer
  (id [_] rid)
  (describe [_] {:parity? true :heavy? false :what "plain Clojure on the JVM, one thread, the reference"})
  (escape! [_ t field] (fill! esc t field)))

(defn renderer [] (->Oracle "clojure-jvm" escape))
