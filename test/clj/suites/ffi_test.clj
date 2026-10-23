;; SPDX-License-Identifier: EPL-2.0
;; cljw.ffi (ADR-0202): dlopen a C library and call it through the
;; register-only call shape.
;;
;; Run by `test/clj/run_suites.clj`. The fixture library is COMPILED HERE from
;; test/e2e/fixtures/ffi/ffi_fixture.c with the system `cc` into a temporary
;; directory, so no binary is committed and the suite always exercises a
;; library built for the host it runs on.
;;
;; `hive-c-abi-live` is the acceptance against the real hive C ABI
;; (`hive_call(op, json) -> char*` + `hive_free`). It reads the libraries from
;; $HIVE_POLYGLOT_NATIVE, else $HOME/PP/hive/hive-polyglot/native, and prints a
;; loud SKIP line and passes when they are absent, so CI stays green.
(ns suites.ffi-test
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.java.io :as io]
            [clojure.java.shell :refer [sh]]
            [clojure.data.json :as json]
            [cljw.ffi :as ffi]))

(def ^:private src "test/e2e/fixtures/ffi/ffi_fixture.c")
(def ^:private dir (str "/tmp/cljw_ffi_suite_" (System/currentTimeMillis)))
(def ^:private so (str dir "/libffi_fixture.so"))

(def ^:private lib (atom nil))

(use-fixtures :once
  (fn [run]
    (.mkdirs (io/file dir))
    (try
      (let [r (sh "cc" "-shared" "-fPIC" "-O1" "-o" so src)]
        (is (zero? (:exit r)) (str "cc failed: " (:err r)))
        (reset! lib (ffi/open so))
        (run))
      (finally
        (when @lib (ffi/close @lib))
        (.delete (io/file so))
        (.delete (io/file dir))))))

(defn- f [name args ret] (ffi/function @lib name args ret))

(defn- ffi-error [thunk]
  (try (thunk) nil
       (catch Exception e (ex-data e))))

(deftest integer-and-double-calls
  (is (= 5 ((f "add_i" [:int :int] :int) 2 3)))
  (is (= 9000000000 ((f "add_l" [:long :long] :long) 4000000000 5000000000)))
  (is (= 7.5 ((f "scale" [:double :long] :double) 2.5 3)))
  (testing "an integer is accepted for a :double"
    (is (= 6.0 ((f "scale" [:double :long] :double) 2 3))))
  (testing ":int returns are sign-extended from the low 32 bits"
    (is (= -7 ((f "neg" [] :int)))))
  (testing ":int arguments are truncated to 32 bits"
    (is (= 1 ((f "add_i" [:int :int] :int) 4294967296 1)))))

(deftest interleaved-register-files
  (testing "longs and doubles keep their order within each register file"
    (is (= 654321 ((f "mixed" [:long :double :long :double :long :double] :long) 1 2.0 3 4.0 5 6.0))))
  (testing "six integer-class arguments, the most the call shape carries"
    (is (= 91 ((f "six_ints" (vec (repeat 6 :long)) :long) 1 2 3 4 5 6))))
  (testing "eight doubles, the most the call shape carries"
    (is (= 204.0 ((f "eight_doubles" (vec (repeat 8 :double)) :double) 1 2 3 4 5 6 7 8)))))

(deftest strings-pointers-and-bytes
  (testing ":string argument and return copy across the boundary"
    (is (= "hi cljw" ((f "greet" [:string] :string) "cljw")))
    (is (= "hi (null)" ((f "greet" [:string] :string) nil))))
  (testing "a callee-allocated string: :pointer, string, then the library's free"
    (let [p ((f "dup_upper" [:string] :pointer) "shout")]
      (is (pos? p))
      (is (= "SHOUT" (ffi/string p)))
      (is (nil? ((f "fixture_free" [:pointer] :void) p)))))
  (testing ":bytes passes a copy of a byte array"
    (testing "(signed -56 is the unsigned byte 200 C reads)"
      (is (= 344 ((f "sum_bytes" [:bytes :long] :long) (byte-array [100 -56 44 0]) 3))))
    (is (= 0 ((f "sum_bytes" [:bytes :long] :long) (byte-array 0) 0))))
  (testing "a NULL return is 0 for :pointer and nil for :string"
    (is (= 0 ((f "null_ptr" [] :pointer))))
    (is (nil? ((f "null_ptr" [] :string))))
    (is (nil? (ffi/string 0)))
    (is (nil? (ffi/string nil))))
  (testing "nil is NULL for :pointer and :string arguments"
    (is (= 1 ((f "is_null" [:pointer] :int) nil)))
    (is (= 1 ((f "is_null" [:string] :int) nil))))
  (testing "bytes copies C memory into a byte array"
    (let [p ((f "dup_upper" [:string] :pointer) "abc")]
      (is (= [65 66 67] (vec (ffi/bytes p 3))))
      ((f "fixture_free" [:pointer] :void) p)))
  (testing "sym answers the address function uses"
    (is (pos? (ffi/sym @lib "add_i")))))

(deftest primitive-arrays-cross-as-contiguous-storage
  (testing ":pointer passes a primitive array's storage, no copy"
    (let [a (double-array [1 2 3])
          b (double-array [4 5 6])]
      (is (= 32.0 ((f "dot" [:pointer :pointer :long] :double) a b 3))))
    (is (= -6 ((f "sum_i32" [:pointer :long] :long) (int-array [1 -2 3 -8]) 4)))
    (is (= 3.75 ((f "sum_f32" [:pointer :long] :double) (float-array [1.5 2.25]) 2))))
  (testing "C writes a :pointer array in place"
    (let [l (long-array 3)]
      ((f "fill_i64" [:pointer :long :long] :void) l 3 9000000000)
      (is (= [9000000000 9000000001 9000000002] (vec l)))))
  (testing ":bytes passes a copy, so C writes do not reach the array"
    (let [b (byte-array [1 2 3])]
      ((f "bump_bytes" [:bytes :long] :void) b 3)
      (is (= [1 2 3] (vec b)))
      ((f "bump_bytes" [:pointer :long] :void) b 3)
      (is (= [2 3 4] (vec b)))))
  (testing "a large byte array crosses whole"
    (let [b (byte-array 65536 1)]
      (is (= 65536 ((f "sum_bytes" [:bytes :long] :long) b 65536)))
      (is (= 65536 ((f "sum_bytes" [:pointer :long] :long) b 65536)))))
  (testing "bytes copies out into a byte array"
    (let [b (byte-array [7 8 9])
          p ((f "dup_upper" [:string] :pointer) "xyz")]
      (is (= [88 89 90] (vec (ffi/bytes p 3))))
      (is (bytes? (ffi/bytes p 3)))
      ((f "fixture_free" [:pointer] :void) p)
      (is (= [7 8 9] (vec b)))))
  (testing "only a byte array is :bytes, only a primitive array is a :pointer"
    (is (= {:ffi/error :arg-type :index 0 :type :bytes}
           (ffi-error #((f "sum_bytes" [:bytes :long] :long) (int-array 2) 2))))
    (is (= {:ffi/error :arg-type :index 0 :type :pointer}
           (ffi-error #((f "sum_bytes" [:pointer :long] :long) (object-array 2) 2))))))

(deftest ordinary-clojure-fns
  (let [add (f "add_i" [:int :int] :int)]
    (is (fn? add))
    (is (= [3 5 7] (map add [1 2 3] [2 3 4])))
    (is (= 10 (apply add [4 6])))
    (is (= 11 (ffi/call @lib "add_i" [:int :int] :int 5 6)))))

(deftest error-paths
  (testing "a library that cannot be opened"
    (let [d (ffi-error #(ffi/open "/no/such/libnothing.so"))]
      (is (= :open (:ffi/error d)))
      (is (= "/no/such/libnothing.so" (:path d)))
      (is (string? (:reason d))))
    (is (re-find #"^ffi: cannot open /no/such/libnothing.so: "
                 (try (ffi/open "/no/such/libnothing.so") (catch Exception e (ex-message e))))))
  (testing "a missing symbol"
    (is (= {:ffi/error :symbol :symbol "no_such_fn"}
           (ffi-error #(f "no_such_fn" [] :void))))
    (is (= :symbol (:ffi/error (ffi-error #(ffi/sym @lib "no_such_fn"))))))
  (testing "signatures are refused at creation, not at call"
    (is (= :signature (:ffi/error (ffi-error #(f "add_i" [:int :float] :int)))))
    (is (= :signature (:ffi/error (ffi-error #(f "add_i" [:int :int] :struct)))))
    (is (= :signature (:ffi/error (ffi-error #(f "six_ints" (vec (repeat 7 :int)) :long)))))
    (is (= :signature (:ffi/error (ffi-error #(f "eight_doubles" (vec (repeat 9 :double)) :double)))))
    (is (= :signature (:ffi/error (ffi-error #(f "add_i" [:void] :int)))))
    (is (= :signature (:ffi/error (ffi-error #(f "null_ptr" [] :bytes))))))
  (testing "a wrong argument count"
    (is (= {:ffi/error :arity :expected 2 :got 1}
           (ffi-error #((f "add_i" [:int :int] :int) 1))))
    (is (= {:ffi/error :arity :expected 2 :got 4}
           (ffi-error #((f "add_i" [:int :int] :int) 1 2 3 4)))))
  (testing "a value of the wrong type"
    (is (= {:ffi/error :arg-type :index 1 :type :int}
           (ffi-error #((f "add_i" [:int :int] :int) 1 "two"))))
    (is (= {:ffi/error :arg-type :index 0 :type :string}
           (ffi-error #((f "greet" [:string] :string) 42))))
    (is (= {:ffi/error :arg-type :index 0 :type :double}
           (ffi-error #((f "scale" [:double :long] :double) "x" 1)))))
  (testing "a closed library: close is idempotent and its functions throw"
    (let [l (ffi/open so)
          add (ffi/function l "add_i" [:int :int] :int)]
      (is (= 3 (add 1 2)))
      (is (nil? (ffi/close l)))
      (is (nil? (ffi/close l)))
      (is (= {:ffi/error :closed} (ffi-error #(add 1 2))))
      (is (= {:ffi/error :closed} (ffi-error #(ffi/function l "add_i" [:int :int] :int))))
      (is (= {:ffi/error :closed} (ffi-error #(ffi/sym l "add_i")))))))

;; ── live: the hive C ABI ────────────────────────────────────────────────────

(defn- native-dir []
  (or (System/getenv "HIVE_POLYGLOT_NATIVE")
      (some-> (System/getenv "HOME") (str "/PP/hive/hive-polyglot/native"))))

(defn- median-ms [f n]
  (let [ts (sort (vec (for [_ (range n)]
                        (let [t0 (System/nanoTime)]
                          (f)
                          (/ (- (System/nanoTime) t0) 1e6)))))]
    (nth ts (quot n 2))))

(defn- hive-call [path op payload]
  (let [l (ffi/open path)]
    (try
      (let [call (ffi/function l "hive_call" [:string :string] :pointer)
            free (ffi/function l "hive_free" [:pointer] :void)
            once (fn []
                   (let [p (call op payload)]
                     (try (ffi/string p) (finally (free p)))))
            text (once)]
        {:envelope (json/read-str text :key-fn keyword)
         :head (subs text 0 (min 160 (count text)))
         :ms (median-ms once 20)})
      (finally (ffi/close l)))))

(deftest hive-c-abi-live
  (let [d (native-dir)
        libs (filter #(.exists (io/file %))
                     (map #(str d "/" %) ["libvectorcraft.so" "libautopdf.so"]))]
    (if (empty? libs)
      (do (println (str "SKIP suites.ffi-test/hive-c-abi-live: no hive C ABI libraries under " d))
          (is true))
      (doseq [path libs]
        (let [{:keys [envelope head ms]} (hive-call path "ops" "{}")]
          (println (str "LIVE " (.getName (io/file path)) " hive_call ops: " head))
          (println (str "LIVE " (.getName (io/file path)) " median of 20: " ms " ms"))
          (is (contains? envelope :ok) (str path " answered a hive envelope")))))))
