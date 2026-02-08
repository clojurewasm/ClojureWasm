;; 03_host_functions_test.clj — E2E test: host function callbacks
;; Verifies: Clojure functions as Wasm imports, callback invocation

(require '[cljw.wasm :as wasm])

;; Host function to capture values
(def log (atom []))

(def my-print-i32
  (fn [n]
    (swap! log conj n)))

(def mod-ref (atom nil))

(def my-print-str
  (fn [offset len]
    (let [m @mod-ref]
      (when m
        (wasm/memory-read m offset len)))))

;; Load module with host imports
(def mod (wasm/load "src/wasm/testdata/04_imports.wasm"
                    {:imports {"env" {"print_i32" my-print-i32
                                      "print_str" my-print-str}}}))
(reset! mod-ref mod)

;; Call greet (invokes print_str host function)
(def greet (wasm/fn mod "greet" {:params [] :results []}))
(greet)

;; Call compute_and_print — adds args, calls print_i32 with result
(def compute (wasm/fn mod "compute_and_print"
               {:params [:i32 :i32] :results []}))
(compute 10 20)
(compute 100 200)

;; Verify captured values
(assert (= [30 300] @log) "Host function callback values should be [30 300]")

;; Batch test
(reset! log [])
(doseq [[a b] [[1 2] [3 4] [5 6]]]
  (compute a b))
(assert (= [3 7 11] @log) "Batch host function values should be [3 7 11]")

(println "PASS: 03_host_functions_test")
