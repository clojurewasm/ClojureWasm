;; cljw calls a Clojure library that jolt compiled to native code.
;;
;;   sh docs/examples/ffi/jolt/build.sh
;;   cljw -M docs/examples/ffi/jolt/jolt_lib.clj docs/examples/ffi/jolt/build
;;
;; A jolt --library build exports jolt_library_init and jolt_lookup; every
;; export! is a function pointer jolt_lookup hands back after the init, and
;; ffi/function-at turns that pointer into a Clojure fn.
(require '[cljw.ffi :as ffi]
         '[clojure.data.json :as json])

(defn- ms-since [t0] (/ (- (System/nanoTime) t0) 1e6))

(def dir (or (first *command-line-args*) "docs/examples/ffi/jolt/build"))
(def lib (ffi/open (str dir "/libdemo.so")))

(let [t0 (System/nanoTime)
      rc (ffi/call lib "jolt_library_init" [:int :pointer] :int 0 nil)]
  (println "jolt_library_init" rc "in" (ms-since t0) "ms"))

(def lookup (ffi/function lib "jolt_lookup" [:string] :pointer))

(defn export
  "The jolt export `name` as a Clojure fn. jolt_lookup answers 0 for a name
  the library does not export, and function-at refuses 0 with
  {:ffi/error :symbol}."
  [name arg-types ret-type]
  (ffi/function-at (lookup name) arg-types ret-type))

(println "jolt_lookup add" (lookup "add") "mandel" (lookup "mandel") "missing" (lookup "missing"))
(println "export missing:" (try (export "missing" [] :int) (catch Exception e (ex-data e))))

(def add (export "add" [:int :int] :int))
(def mandel (export "mandel" [:double :double :int] :int))
(println "add(2,40)" (add 2 40) "mandel(-0.75,0.1,1000)" (mandel -0.75 0.1 1000))

(let [t0 (System/nanoTime)
      sum (reduce + (for [y (range 200) x (range 300)]
                      (mandel (+ -2.0 (/ (* 3.0 x) 300)) (+ -1.0 (/ (* 2.0 y) 200)) 255)))]
  (println "grid 300x200 sum" sum "in" (ms-since t0) "ms"))

;; The hive C ABI (ADR-0202, as hive_call.clj speaks it) over looked-up
;; pointers: the answer is allocated by the library and freed by it.
(let [call (export "hive_call" [:string :string] :pointer)
      free (export "hive_free" [:pointer] :void)
      hive (fn [op payload]
             (let [p (call op (json/write-str payload))]
               (try (json/read-str (ffi/string p) :key-fn keyword)
                    (finally (free p)))))]
  (prn (hive "ops" {}))
  (prn (hive "add" {:a 2 :b 40})))
