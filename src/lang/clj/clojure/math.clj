;; clojure.math — thin Clojure wrappers over the host `Math` static methods
;; (D-232). cljw resolves `Math/*` interop without reflection, so each fn is a
;; one-line delegate. Mirrors the JVM clojure.math surface: trig, hyperbolics,
;; exp/log family, roots, rounding, angle conversion, the IEEE-754 helpers
;; (ulp / scalb / next-after / next-up / next-down / get-exponent / copy-sign /
;; IEEE-remainder / rint), and the integer *-exact / floor-div / floor-mod set.
;;
;; Loaded by bootstrap.zig after core.clj. The (in-ns) header is mandatory.

(ns clojure.math (:refer-clojure))

(def ^:const PI Math/PI)
(def ^:const E Math/E)

(defn sin [a] (Math/sin a))
(defn cos [a] (Math/cos a))
(defn tan [a] (Math/tan a))
(defn asin [a] (Math/asin a))
(defn acos [a] (Math/acos a))
(defn atan [a] (Math/atan a))
(defn atan2 [y x] (Math/atan2 y x))
(defn sinh [a] (Math/sinh a))
(defn cosh [a] (Math/cosh a))
(defn tanh [a] (Math/tanh a))
(defn to-radians [deg] (Math/toRadians deg))
(defn to-degrees [r] (Math/toDegrees r))

(defn exp [a] (Math/exp a))
(defn expm1 [a] (Math/expm1 a))
(defn log [a] (Math/log a))
(defn log10 [a] (Math/log10 a))
(defn log1p [a] (Math/log1p a))

(defn sqrt [a] (Math/sqrt a))
(defn cbrt [a] (Math/cbrt a))
(defn pow [a b] (Math/pow a b))
(defn hypot [x y] (Math/hypot x y))

(defn ceil [a] (Math/ceil a))
(defn floor [a] (Math/floor a))
(defn rint [a] (Math/rint a))
(defn round [a] (Math/round a))
(defn signum [a] (Math/signum a))

(defn ulp [a] (Math/ulp a))
(defn scalb [d scale-factor] (Math/scalb d scale-factor))
(defn next-after [start direction] (Math/nextAfter start direction))
(defn next-up [d] (Math/nextUp d))
(defn next-down [d] (Math/nextDown d))
(defn get-exponent [d] (Math/getExponent d))
(defn copy-sign [magnitude sign] (Math/copySign magnitude sign))
(defn IEEE-remainder [dividend divisor] (Math/IEEEremainder dividend divisor))

(defn floor-div [x y] (Math/floorDiv x y))
(defn floor-mod [x y] (Math/floorMod x y))
(defn add-exact [x y] (Math/addExact x y))
(defn subtract-exact [x y] (Math/subtractExact x y))
(defn multiply-exact [x y] (Math/multiplyExact x y))
(defn negate-exact [a] (Math/negateExact a))
(defn increment-exact [a] (Math/incrementExact a))
(defn decrement-exact [a] (Math/decrementExact a))
