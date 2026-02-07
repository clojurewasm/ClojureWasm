;; 03_host_functions.clj — Clojure functions callable from Wasm
;; Run: ./zig-out/bin/cljw examples/wasm/03_host_functions.clj
;;
;; Demonstrates host function injection: Clojure functions registered as
;; Wasm imports, called by Wasm code during execution.

;; ============================================================
;; Part 1: Basic host function — print_i32
;; ============================================================

;; Atom to capture values printed by Wasm
(def log (atom []))

;; Clojure functions that Wasm will call
(def my-print-i32
  (fn [n]
    (swap! log conj n)
    (println "  [host] print_i32:" n)))

;; Module ref for memory access in print_str callback
(def mod-ref (atom nil))

(def my-print-str
  (fn [offset len]
    (let [m @mod-ref]
      (when m
        (let [s (wasm/memory-read m offset len)]
          (println "  [host] print_str:" s))))))

;; Load module with host imports
(def mod (wasm/load "src/wasm/testdata/04_imports.wasm"
                    {:imports {"env" {"print_i32" my-print-i32
                                      "print_str" my-print-str}}}))
(reset! mod-ref mod)

;; ============================================================
;; Part 2: Call Wasm functions that invoke host callbacks
;; ============================================================

;; greet calls print_str(0, 16) which reads "Hello from Wasm!" from memory
(def greet (wasm/fn mod "greet" {:params [] :results []}))
(println "Calling greet:")
(greet)

;; compute_and_print(10, 20) adds args and calls print_i32(30)
(def compute (wasm/fn mod "compute_and_print"
               {:params [:i32 :i32] :results []}))
(println "Calling compute_and_print(10, 20):")
(compute 10 20)

(println "Calling compute_and_print(100, 200):")
(compute 100 200)

;; ============================================================
;; Part 3: Verify captured values
;; ============================================================

(println "Captured log:" @log)
;; => [30 300]

(assert (= [30 300] @log) "Host function callback values mismatch")

;; ============================================================
;; Part 4: Higher-order composition with host callbacks
;; ============================================================

;; Reset log
(reset! log [])

;; Use map to call compute_and_print with multiple pairs
(doseq [[a b] [[1 2] [3 4] [5 6]]]
  (compute a b))

(println "Batch log:" @log)
;; => [3 7 11]

(assert (= [3 7 11] @log) "Batch host function values mismatch")

(println "03_host_functions done.")
