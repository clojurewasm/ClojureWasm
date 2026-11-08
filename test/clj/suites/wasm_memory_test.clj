;; The (ptr,len) linear-memory surface (ADR-0192, arrays ADR-0204): the host
;; fills the buffer a guest's pointer names and reads back what the guest
;; wrote; every element type round-trips through the wasm memory model
;; (little-endian, unaligned-tolerant, i64 exact past the i48 window); every
;; failure is a catchable exception naming the fn the user wrote, never a host
;; panic on caller data. Needs the -Dwasm binary.
;;
;; Migrated from test/e2e/phase16_wasm_memory.sh and its probe fixture; the
;; probe's line labels are the assertion messages.
(ns suites.wasm-memory-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]))

(def ^:private kernel "test/e2e/fixtures/wasm/mem_kernel.wasm")

(defn- message [f]
  (try (f) "NOT-CAUGHT" (catch Exception e (.getMessage e))))

(defmacro ^:private raises [label prefix form]
  `(is (str/includes? (message (fn [] ~form)) ~prefix) ~label))

(deftest wasm-memory-roundtrip
  (let [m (wasm/load kernel)]
    (is (= 65536 (wasm/mem-size m)) "size: the memory answers in BYTES, not pages")
    (is (= 4 (wasm/mem-write! m :f64 0 [1.0 2.0 3.0 4.0])) "wrote")
    (is (= 10.0 (wasm/call m "sum_f64" 0 4)) "sum: the guest read the host's buffer")
    (is (= 25.0 (wasm/call m "scale_f64" 0 4 2.5)) "newsum")
    (is (= [2.5 5.0 7.5 10.0] (wasm/mem-read m :f64 0 4)) "scaled: the host read the guest's write")))

(deftest wasm-memory-dtypes
  (let [m (wasm/load kernel)]
    (wasm/mem-write! m :f64 64 [1.5])
    (is (= [0 0 0 0 0 0 248 63] (wasm/mem-read m :u8 64 8)) "as-u8: little-endian bytes")
    (testing "wasm-memory-i64-exact: 2^53+1 is not an f64, so equality proves no float"
      (wasm/mem-write! m :i64 128 [9007199254740993 -1])
      (is (= [9007199254740993 -1] (wasm/mem-read m :i64 128 2)) "i64")
      (is (= 9007199254740993 (first (wasm/mem-read m :i64 128 1))) "i64-exact"))
    (wasm/mem-write! m :u32 200 [4294967295])
    (is (= [4294967295] (wasm/mem-read m :u32 200 1)) "u32")
    (is (= [-1] (wasm/mem-read m :i32 200 1)) "i32 over the same bytes")
    (wasm/mem-write! m :f64 301 [7.25])
    (is (= [7.25] (wasm/mem-read m :f64 301 1)) "unaligned")))

(deftest wasm-memory-arrays
  (let [m (wasm/load kernel)]
    (is (= 4 (wasm/mem-write! m :f64 0 (double-array [1 2 3 4]))) "arr-wrote")
    (is (= 20.0 (wasm/call m "scale_f64" 0 4 2.0)) "arr-newsum")
    (let [d (wasm/mem-read-array m :f64 0 4)]
      (is (= [2.0 4.0 6.0 8.0] (vec d)) "arr-f64")
      (is (= :double (cljw.internal/__array-kind d)) "arr-f64 answers a typed array"))
    (doseq [[dt arr] [[:i8 (byte-array [-1 2 127])]
                      [:i16 (short-array [-300 2 32767])]
                      [:i32 (int-array [-70000 2 2147483647])]
                      [:i64 (long-array [9007199254740993 -1 2])]
                      [:f32 (float-array [1.5 -2.25 3])]
                      [:f64 (double-array [1.5 -2.25 3])]]]
      (wasm/mem-write! m dt 1000 arr)
      (is (= (vec arr) (vec (wasm/mem-read-array m dt 1000 3))) (str "arr-rt " dt)))
    (wasm/mem-write! m :u16 2000 [65535])
    (wasm/mem-write! m :u32 2008 [4294967295])
    (is (= [65535] (vec (wasm/mem-read-array m :u16 2000 1))) "arr-unsigned u16")
    (is (= [4294967295] (vec (wasm/mem-read-array m :u32 2008 1))) "arr-unsigned u32")
    (wasm/mem-write! m :f64 3000 (int-array [5 6]))
    (is (= [5.0 6.0] (wasm/mem-read m :f64 3000 2))
        "arr-convert: a kind that is not the dtype's layout converts element by element")
    (raises "arr-object" "wasm/mem-write!: the data argument must be a vector of numbers"
            (wasm/mem-write! m :f64 0 (object-array 1)))
    (raises "arr-range" "wasm/mem-write!: element 1 is outside this element type's range"
            (wasm/mem-write! m :i8 0 (int-array [1 300])))
    (raises "arr-oob" "wasm/mem-read-array: 1 element(s) at byte offset 65530"
            (wasm/mem-read-array m :f64 65530 1))))

(deftest wasm-memory-catchable
  (let [m (wasm/load kernel)]
    (raises "no-memory" "wasm/mem-size: this module exports no linear memory"
            (wasm/mem-size (wasm/load "docs/examples/wasm/add.wasm")))
    (raises "bad-handle" "wasm/mem-size: the first argument must be a loaded wasm module"
            (wasm/mem-size 42))
    (raises "bad-dtype" "wasm/mem-read: the element type must be one of" (wasm/mem-read m :f16 0 1))
    (raises "bad-index" "wasm/mem-read: the byte offset and the element count must both be integers"
            (wasm/mem-read m :f64 1.5 1))
    (raises "oob" "wasm/mem-read: 1 element(s) at byte offset 65530" (wasm/mem-read m :f64 65530 1))
    (raises "negative" "wasm/mem-read: 1 element(s) at byte offset -8" (wasm/mem-read m :f64 -8 1))
    (raises "overflow" "wasm/mem-read: 9223372036854775807 element(s)"
            (wasm/mem-read m :f64 0 9223372036854775807))
    (raises "bad-data" "wasm/mem-write!: the data argument must be a vector of numbers"
            (wasm/mem-write! m :f64 0 "nope"))
    (raises "bad-element" "wasm/mem-write!: element 1 is not a number" (wasm/mem-write! m :i32 0 [1 :x 3]))
    (raises "element-range" "wasm/mem-write!: element 1 is outside this element type's range"
            (wasm/mem-write! m :u8 0 [1 300]))
    (raises "element-fraction" "wasm/mem-write!: element 0 is not an integer"
            (wasm/mem-write! m :i32 0 [1.5]))))
