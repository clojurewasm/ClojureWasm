(ns fractal.palette
  "The one colouring rule: an escape count and |z|^2 become an RGBA8 pixel.
  Interior points (count = limit) are opaque black; the rest follow the smooth
  escape count through a periodic triangular wave per channel. Byte for byte
  the rule of kernel.zig, kernel.c, kernel.rs and mandel.clj."
  (:require [fractal.tile :as tile]))

(def ^:private ^:const inv-ln2 1.4426950408889634)

(defn- channel ^long [^double phase ^long c]
  (let [t (+ phase (/ (double c) 3.0))
        wave (- 1.0 (Math/abs (- (* 2.0 (- t (Math/floor t))) 1.0)))]
    (long (* wave 255.0))))

(defn rgba
  "[r g b a] of one pixel."
  [^long n ^long limit ^double mag2]
  (if (== n limit)
    [0 0 0 255]
    (let [bounded (if (Double/isFinite mag2) (Math/max mag2 4.000001) 1.0e300)
          l2 (* (Math/log (* 0.5 (* (Math/log bounded) inv-ln2))) inv-ln2)
          phase (* 0.025 (- (+ (double n) 1.0) l2))]
      [(channel phase 0) (channel phase 1) (channel phase 2) 255])))

(defn paint
  "RGBA8 bytes, row-major, for an EscapeField of tile t."
  ^bytes [{:keys [^ints counts ^doubles mag2]} t]
  (let [n (tile/pixels t)
        limit (long (:iter t))
        out (byte-array (* 4 n))]
    (dotimes [p n]
      (let [[r g b a] (rgba (aget counts p) limit (aget mag2 p))
            o (* 4 p)]
        (aset out o (unchecked-byte r))
        (aset out (+ o 1) (unchecked-byte g))
        (aset out (+ o 2) (unchecked-byte b))
        (aset out (+ o 3) (unchecked-byte a))))
    out))

(defn checksum
  "The golden checksum of an RGBA8 framebuffer."
  ^long [^bytes pixels]
  (areduce pixels i acc 1 (mod (+ (* acc 31) (bit-and 255 (aget pixels i))) 2147483647)))
