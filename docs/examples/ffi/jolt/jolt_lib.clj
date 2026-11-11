;; cljw calls a Clojure library that jolt compiled to native code.
;;
;;   sh docs/examples/ffi/jolt/build.sh
;;   cljw -M docs/examples/ffi/jolt/jolt_lib.clj docs/examples/ffi/jolt/build
;;
;; A jolt --library build exports jolt_library_init and jolt_lookup only;
;; every export! is a function pointer jolt_lookup hands back. This script
;; runs the init and the lookups against libdemo.so directly, then calls the
;; exports through libdemo_named.so, a C shim that re-exports the looked-up
;; pointers by name. With call-by-address (card CLJW-FFI-CALL-ADDRESS) the
;; shim goes away: see `direct` below.
(require '[cljw.ffi :as ffi])

(defn- ms-since [t0] (/ (- (System/nanoTime) t0) 1e6))

(defn direct
  "The finished form: no shim. PENDING branch feat/ffi-call-address, which
  adds (ffi/function addr arg-types ret-type); until it lands the first
  ffi/function call here throws."
  [lookup]
  {:add (ffi/function (lookup "add") [:int :int] :int)
   :mandel (ffi/function (lookup "mandel") [:double :double :int] :int)})

(def dir (or (first *command-line-args*) "docs/examples/ffi/jolt/build"))
;; The shim links libdemo.so, so both handles share one jolt runtime.
(def named (ffi/open (str dir "/libdemo_named.so")))
(def jolt (ffi/open (str dir "/libdemo.so")))

(let [t0 (System/nanoTime)
      rc (ffi/call named "shim_init" [] :int)]
  (println "jolt_library_init" rc "in" (ms-since t0) "ms"))

(def lookup (ffi/function jolt "jolt_lookup" [:string] :pointer))
(println "jolt_lookup add" (lookup "add") "mandel" (lookup "mandel") "missing" (lookup "missing"))

(def add (ffi/function named "add" [:int :int] :int))
(def mandel (ffi/function named "mandel" [:double :double :int] :int))
(println "add(2,40)" (add 2 40) "mandel(-0.75,0.1,1000)" (mandel -0.75 0.1 1000))

(let [t0 (System/nanoTime)
      sum (reduce + (for [y (range 200) x (range 300)]
                      (mandel (+ -2.0 (/ (* 3.0 x) 300)) (+ -1.0 (/ (* 2.0 y) 200)) 255)))]
  (println "grid 300x200 sum" sum "in" (ms-since t0) "ms"))

(println "direct call-by-address:"
         (try (let [{f :add} (direct lookup)] (f 2 40))
              (catch Exception e (str "pending, " (ex-message e)))))
