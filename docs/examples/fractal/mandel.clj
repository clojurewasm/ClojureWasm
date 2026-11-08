;; Plain Clojure Mandelbrot: the same pixel math and palette as the wasm
;; kernels, with no wasm and no library. Portable across cljw, bb and JVM
;; Clojure; the server's cljw-clj engine and bench.clj run it on cljw.
;; Iteration totals match the kernels exactly.
(ns fractal.mandel)

(def ^:const inv-ln2 1.4426950408889634)

(defn- log2 [x] (* (Math/log x) inv-ln2))

(defn- finite? [x] (== 0.0 (- x x)))

(defn- color! [^bytes fb pixel n limit magnitude]
  (let [o (* 4 pixel)]
    (aset fb (+ o 3) (unchecked-byte 255))
    (if (== n limit)
      (do (aset fb o (unchecked-byte 0))
          (aset fb (+ o 1) (unchecked-byte 0))
          (aset fb (+ o 2) (unchecked-byte 0)))
      (let [bounded (if (finite? magnitude) (max magnitude 4.000001) 1.0e300)
            smooth (- (+ (double n) 1.0) (log2 (* 0.5 (log2 bounded))))
            phase (* smooth 0.025)]
        (dotimes [ch 3]
          (let [t (+ phase (/ (double ch) 3.0))
                wave (- 1.0 (Math/abs (- (* 2.0 (- t (Math/floor t))) 1.0)))]
            (aset fb (+ o ch) (unchecked-byte (long (* wave 255.0))))))))))

(defn render
  "Render w x h RGBA8 pixels of the view (cx, cy, scale) into fb, a byte-array
  of at least w*h*4 bytes. Returns total iterations, as the kernels' render."
  [^bytes fb cx cy scale w h max-iter]
  (let [limit (min max-iter 67108863)
        hw (/ (double w) 2.0)
        hh (/ (double h) 2.0)]
    (loop [y 0 total 0]
      (if (< y h)
        (let [ci (+ cy (* (- (double y) hh) scale))
              row (loop [x 0 acc 0]
                    (if (< x w)
                      (let [cr (+ cx (* (- (double x) hw) scale))
                            [n zr zi] (loop [n 0 zr 0.0 zi 0.0]
                                        (if (and (< n limit) (<= (+ (* zr zr) (* zi zi)) 4.0))
                                          (recur (inc n)
                                                 (+ (- (* zr zr) (* zi zi)) cr)
                                                 (+ (* (* 2.0 zr) zi) ci))
                                          [n zr zi]))]
                        (color! fb (+ (* y w) x) n limit (+ (* zr zr) (* zi zi)))
                        (recur (inc x) (+ acc n)))
                      acc))]
          (recur (inc y) (+ total row)))
        total))))
