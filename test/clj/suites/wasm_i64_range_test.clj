;; Full-range integers across the wasm boundary (CLJW-WASM-I64-FULL-RANGE).
;; A cljw integer is an immediate only inside the i48 NaN-box window (about
;; +/-2^47); past it the value is a heap Long. `wasm/call` (and the dot form,
;; which shares its path) refused a heap Long as an i64 arg ("argument is not a
;; number") and lifted an i64 result past the window to a lossy Double. Every
;; case is a round trip through an identity export, so a pass proves lower and
;; lift both. Needs the -Dwasm binary (the gate configuration).
(ns suites.wasm-i64-range-test
  (:require [clojure.test :refer [deftest is testing]]))

(def ^:private fixture "test/e2e/fixtures/wasm/i64_range.wasm")
(def ^:private echo "test/e2e/fixtures/wasm/echo.component.wasm")

(def ^:private i64-edges
  [0 1 -1
   70368744177664 -70368744177664        ; +/-2^46, inside the window
   140737488355328 -140737488355328      ; +/-2^47, the first heap Long is +2^47
   9007199254740993 -9007199254740993    ; +/-(2^53+1), not representable as f64
   Long/MIN_VALUE Long/MAX_VALUE])

(defn- exact-long? [want got]
  (and (instance? Long got) (= want got)))

(defn- msg [f]
  (try (f) :not-raised (catch Throwable e (.getMessage e))))

(def ^:private out-of-range
  "wasm/call: an integer argument is out of range for the parameter type")

(deftest i64-args-and-results-round-trip
  (let [m (wasm/load fixture)]
    (doseq [v i64-edges]
      (testing (str "wasm/call " v)
        (is (exact-long? v (wasm/call m "id64" v))))
      (testing (str "dot form " v)
        (is (exact-long? v (.id64 m v)))))))

(deftest u64-top-bit-reads-as-signed-long
  ;; wasm i64 is signless: a guest u64 with the top bit set (what
  ;; `@bitReverse(@as(u64, 1))` returns) is the negative Long with the same
  ;; bits, JVM semantics, as cljw.ffi's :long. Was -9.223372036854776E18.
  (is (exact-long? Long/MIN_VALUE (wasm/call (wasm/load fixture) "top_bit"))))

(deftest several-i64-results
  (let [[a b] (wasm/call (wasm/load fixture) "swap64" Long/MIN_VALUE 9007199254740993)]
    (is (exact-long? 9007199254740993 a))
    (is (exact-long? Long/MIN_VALUE b))))

(deftest i32-and-f64-params
  (let [m (wasm/load fixture)]
    (doseq [v [-2147483648 2147483647 0 -1]]
      (is (exact-long? v (wasm/call m "id32" v))))
    (testing "a heap Long widens to an f64 param, as `double` does"
      (is (= 1.40737488355328E14 (wasm/call m "idf64" 140737488355328))))))

(deftest linear-memory
  (let [m (wasm/load fixture)]
    (wasm/mem-write! m :i64 0 i64-edges)
    (is (every? true? (map exact-long? i64-edges (wasm/mem-read m :i64 0 (count i64-edges)))))
    (wasm/mem-write! m :u32 256 [4294967295 0])
    (is (= [4294967295 0] (wasm/mem-read m :u32 256 2)))
    (wasm/mem-write! m :i32 264 [-2147483648 2147483647])
    (is (= [-2147483648 2147483647] (wasm/mem-read m :i32 264 2)))
    (testing "a heap Long widens into an :f64 element"
      (wasm/mem-write! m :f64 512 [140737488355328])
      (is (= [1.40737488355328E14] (wasm/mem-read m :f64 512 1))))))

(deftest refusals-are-catchable
  ;; An integral 2^63 float passed the old `> maxInt(i64)` test (maxInt as an
  ;; f64 rounds to 2^63) and reached `@intFromFloat`: a ReleaseSafe host panic.
  (let [m (wasm/load fixture)]
    (is (= out-of-range (msg #(wasm/call m "id64" 9223372036854775808N))))
    (is (= out-of-range (msg #(wasm/call m "id64" -9223372036854775809N))))
    (is (= out-of-range (msg #(wasm/call m "id32" 140737488355328))))
    (is (= out-of-range (msg #(wasm/call m "id64" 9.223372036854775807E18))))
    (is (re-find #"^wasm/mem-write!: element 0 is outside this element type's range"
                 (str (msg #(wasm/mem-write! m :i64 0 [9.223372036854775807E18])))))))

(deftest wit-u64
  ;; The component path shares the integer coercion. A u64 above
  ;; Long/MAX_VALUE is unsigned by its WIT type, so it lifts as an exact BigInt
  ;; (component.zig `bigFromU64`), not a wrapped Long.
  (doseq [v [140737488355328 9007199254740993 Long/MAX_VALUE]]
    (is (exact-long? v (wasm/component-invoke echo "echo-u64" v))))
  (is (= 18446744073709551615N (wasm/component-invoke echo "echo-u64" 18446744073709551615N))))
