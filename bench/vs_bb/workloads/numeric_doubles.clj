;; numeric doubles: mandelbrot escape-time loop plus a Math/sqrt sum.
(defn mandel [w h maxit]
  (loop [y 0 total 0]
    (if (< y h)
      (recur (inc y)
             (loop [x 0 total total]
               (if (< x w)
                 (let [cr (- (* 3.0 (/ x (double w))) 2.0)
                       ci (- (* 2.0 (/ y (double h))) 1.0)
                       it (loop [zr 0.0 zi 0.0 i 0]
                            (if (and (< i maxit) (< (+ (* zr zr) (* zi zi)) 4.0))
                              (recur (+ (- (* zr zr) (* zi zi)) cr) (+ (* 2.0 zr zi) ci) (inc i))
                              i))]
                   (recur (inc x) (+ total it)))
                 total)))
      total)))
(defn sqrts [n] (loop [i 0 s 0.0] (if (< i n) (recur (inc i) (+ s (Math/sqrt (double i)))) s)))
(let [t0 (System/nanoTime) r (+ (mandel 240 160 60) (long (sqrts 1500000)))]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
