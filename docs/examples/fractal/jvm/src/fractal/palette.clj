(ns fractal.palette
  "The one colouring rule: an escape count and |z|^2 become an RGBA8 pixel.
  Interior points (count = limit) are opaque black; the rest follow the smooth
  escape count through a periodic triangular wave per channel. Byte for byte
  the rule of kernel.zig, kernel.c, kernel.rs and mandel.clj."
  (:require [fractal.tile :as tile]))

(def ^:private ^:const inv-ln2 1.4426950408889634)

(def rule
  "The palette as data: phase speed per smooth escape count, and the phase
  offset of the red, green and blue waves. Every engine uses this rule."
  {:speed 0.025 :offsets [0.0 (/ 1.0 3.0) (/ 2.0 3.0)]})

(defn phase
  "Palette phase of an escaped pixel: speed * smooth escape count."
  ^double [^long n ^double mag2 ^double speed]
  (let [bounded (if (Double/isFinite mag2) (Math/max mag2 4.000001) 1.0e300)
        l2 (* (Math/log (* 0.5 (* (Math/log bounded) inv-ln2))) inv-ln2)]
    (* speed (- (+ (double n) 1.0) l2))))

(defn channel
  "One channel at phase and offset: a triangular wave, 0..255."
  ^long [^double phase ^double offset]
  (let [t (+ phase offset)
        wave (- 1.0 (Math/abs (- (* 2.0 (- t (Math/floor t))) 1.0)))]
    (long (* wave 255.0))))

(defn rgba
  "[r g b a] of one pixel under palette rule r (default `rule`)."
  ([n limit mag2] (rgba rule n limit mag2))
  ([{:keys [speed offsets]} n limit mag2]
   (if (== (long n) (long limit))
     [0 0 0 255]
     (let [ph (phase n mag2 speed)]
       (conj (mapv #(channel ph %) offsets) 255)))))

(defn- put-interior! [^bytes out ^long o]
  (aset out o (byte 0))
  (aset out (+ o 1) (byte 0))
  (aset out (+ o 2) (byte 0))
  (aset out (+ o 3) (unchecked-byte 255)))

(defn- put-colour! [^bytes out ^long o ^double ph ^doubles offsets]
  (aset out o (unchecked-byte (channel ph (aget offsets 0))))
  (aset out (+ o 1) (unchecked-byte (channel ph (aget offsets 1))))
  (aset out (+ o 2) (unchecked-byte (channel ph (aget offsets 2))))
  (aset out (+ o 3) (unchecked-byte 255)))

(defn paint
  "RGBA8 bytes, row-major, for an EscapeField of tile t: `rgba` per pixel
  under palette rule r (default `rule`), rows painted in parallel."
  (^bytes [field t] (paint rule field t))
  (^bytes [r {:keys [^ints counts ^doubles mag2]} t]
   (let [w (long (:w t))
         limit (long (:iter t))
         speed (double (:speed r))
         offsets (double-array (:offsets r))
         out (byte-array (* 4 (tile/pixels t)))]
     (.forEach (.parallel (java.util.stream.IntStream/range 0 (:h t)))
               (reify java.util.function.IntConsumer
                 (accept [_ y]
                   (let [row (* (long y) w)]
                     (dotimes [x w]
                       (let [p (+ row x)
                             n (aget counts p)]
                         (if (== n limit)
                           (put-interior! out (* 4 p))
                           (put-colour! out (* 4 p) (phase n (aget mag2 p) speed) offsets))))))))
     out)))

(defn checksum
  "The golden checksum of an RGBA8 framebuffer."
  ^long [^bytes pixels]
  (areduce pixels i acc 1 (mod (+ (* acc 31) (bit-and 255 (aget pixels i))) 2147483647)))
