;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.math API (originally Alex Miller; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.math — thin Clojure wrappers over the host `Math` static methods
;; (D-232). cljw resolves `Math/*` interop without reflection, so each fn is a
;; one-line delegate. Mirrors the JVM clojure.math surface: trig, hyperbolics,
;; exp/log family, roots, rounding, angle conversion, the IEEE-754 helpers
;; (ulp / scalb / next-after / next-up / next-down / get-exponent / copy-sign /
;; IEEE-remainder / rint), and the integer *-exact / floor-div / floor-mod set.
;;
;; Loaded by bootstrap.zig after core.clj. The (in-ns) header is mandatory.

(ns clojure.math (:refer-clojure))

(def ^:const PI
  "Constant for the ratio of a circle's circumference to its diameter."
  Math/PI)
(def ^:const E
  "Constant for the base of the natural logarithms."
  Math/E)

(defn sin
  "Returns the sine of an angle given in radians." [a] (Math/sin a))
(defn cos
  "Returns the cosine of an angle given in radians." [a] (Math/cos a))
(defn tan
  "Returns the tangent of an angle given in radians." [a] (Math/tan a))
(defn asin
  "Returns the arc sine of a, in the range -pi/2 through pi/2." [a] (Math/asin a))
(defn acos
  "Returns the arc cosine of a, in the range 0.0 through pi." [a] (Math/acos a))
(defn atan
  "Returns the arc tangent of a, in the range -pi/2 through pi/2." [a] (Math/atan a))
(defn atan2
  "Returns the angle theta from the conversion of rectangular coordinates
  (x, y) to polar coordinates (r, theta). Unlike atan, the signs of both
  arguments are used, so the result covers all four quadrants." [y x] (Math/atan2 y x))
(defn sinh
  "Returns the hyperbolic sine of x, (e^x - e^-x)/2." [a] (Math/sinh a))
(defn cosh
  "Returns the hyperbolic cosine of x, (e^x + e^-x)/2." [a] (Math/cosh a))
(defn tanh
  "Returns the hyperbolic tangent of x, sinh(x)/cosh(x)." [a] (Math/tanh a))
(defn to-radians
  "Converts an angle in degrees to an approximately equivalent angle in radians." [deg] (Math/toRadians deg))
(defn to-degrees
  "Converts an angle in radians to an approximately equivalent angle in degrees." [r] (Math/toDegrees r))

(defn exp
  "Returns Euler's number e raised to the power of a." [a] (Math/exp a))
(defn expm1
  "Returns e^x - 1. Near zero this is much more accurate than (dec (exp x)),
  which loses precision to cancellation." [a] (Math/expm1 a))
(defn log
  "Returns the natural logarithm (base e) of a." [a] (Math/log a))
(defn log10
  "Returns the logarithm base 10 of a." [a] (Math/log10 a))
(defn log1p
  "Returns the natural logarithm of 1 + x. Near zero this is much more
  accurate than (log (inc x))." [a] (Math/log1p a))

(defn sqrt
  "Returns the positive square root of a." [a] (Math/sqrt a))
(defn cbrt
  "Returns the cube root of a. Unlike sqrt this is defined for negative
  arguments: (cbrt -8.0) is -2.0." [a] (Math/cbrt a))
(defn pow
  "Returns a raised to the power of b." [a b] (Math/pow a b))
(defn hypot
  "Returns sqrt(x^2 + y^2) without the intermediate overflow or underflow
  that computing it directly would suffer." [x y] (Math/hypot x y))

(defn ceil
  "Returns the smallest double greater than or equal to a that is a
  mathematical integer." [a] (Math/ceil a))
(defn floor
  "Returns the largest double less than or equal to a that is a
  mathematical integer." [a] (Math/floor a))
(defn rint
  "Returns the double closest to a that is a mathematical integer. When two
  are equally close, the EVEN one is returned — unlike round, which breaks
  ties upward." [a] (Math/rint a))
(defn round
  "Returns the closest long to a, breaking ties by rounding up. Equivalent
  to (long (floor (+ a 0.5)))." [a] (Math/round a))
(defn signum
  "Returns 1.0 if d is positive, -1.0 if negative, and d itself if it is
  zero or NaN." [a] (Math/signum a))

(defn ulp
  "Returns the size of an ulp (unit in the last place) of d — the distance
  from d to the next larger double in magnitude." [a] (Math/ulp a))
(defn scalb
  "Returns d * 2^scaleFactor, computed by adjusting the exponent directly
  rather than by multiplying, so it is exact and cannot lose precision." [d scale-factor] (Math/scalb d scale-factor))
(defn next-after
  "Returns the double adjacent to start in the direction of direction.
  Returns direction itself when the two are equal." [start direction] (Math/nextAfter start direction))
(defn next-up
  "Returns the double adjacent to d in the direction of positive infinity." [d] (Math/nextUp d))
(defn next-down
  "Returns the double adjacent to d in the direction of negative infinity." [d] (Math/nextDown d))
(defn get-exponent
  "Returns the unbiased exponent of d — the n in d = m * 2^n with m in
  [1, 2)." [d] (Math/getExponent d))
(defn copy-sign
  "Returns magnitude with the sign of sign." [magnitude sign] (Math/copySign magnitude sign))
(defn IEEE-remainder
  "Returns the remainder of dividend/divisor as prescribed by IEEE 754:
  dividend - divisor * n, where n is the integer closest to the exact
  quotient (ties going to the even n)." [dividend divisor] (Math/IEEEremainder dividend divisor))

(defn floor-div
  "Returns the largest integer less than or equal to x/y. Unlike quot, this
  rounds toward negative infinity, so (floor-div -7 2) is -4." [x y] (Math/floorDiv x y))
(defn floor-mod
  "Returns x - (floor-div x y) * y — the remainder with the sign of the
  DIVISOR, so (floor-mod -7 2) is 1 where (rem -7 2) is -1." [x y] (Math/floorMod x y))
(defn add-exact
  "Returns the sum of x and y, throwing ArithmeticException on overflow
  rather than wrapping." [x y] (Math/addExact x y))
(defn subtract-exact
  "Returns the difference of x and y, throwing ArithmeticException on
  overflow rather than wrapping." [x y] (Math/subtractExact x y))
(defn multiply-exact
  "Returns the product of x and y, throwing ArithmeticException on overflow
  rather than wrapping." [x y] (Math/multiplyExact x y))
(defn negate-exact
  "Returns the negation of a, throwing ArithmeticException on overflow — the
  one case being the most negative long, whose negation is not representable." [a] (Math/negateExact a))
(defn increment-exact
  "Returns a + 1, throwing ArithmeticException on overflow rather than
  wrapping." [a] (Math/incrementExact a))
(defn decrement-exact
  "Returns a - 1, throwing ArithmeticException on overflow rather than
  wrapping." [a] (Math/decrementExact a))
