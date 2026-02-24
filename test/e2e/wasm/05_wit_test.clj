;; 05_wit_test.clj — E2E test: WIT-powered string auto-marshalling
;; Verifies: WIT loading, wasm/describe, string marshalling

(require '[cljw.wasm :as wasm])

;; Part 1: Load with WIT
(def greet-mod (wasm/load "src/app/wasm/testdata/10_greet.wasm"
                          {:wit "src/app/wasm/testdata/10_greet.wit"}))

;; Part 2: WIT describe
(let [desc (wasm/describe greet-mod)]
  (assert (map? desc) "describe should return a map")
  (assert (contains? desc "greet") "describe should contain 'greet'"))

;; Core exports comparison
(let [exports (wasm/exports greet-mod)]
  (assert (contains? exports "greet") "Core exports should contain 'greet'")
  (assert (contains? exports "cabi_realloc") "Should have cabi_realloc"))

;; Part 3: String marshalling — greet returns exact greeting string
(def greet (wasm/fn greet-mod "greet"))
(assert (= "Hello, World!" (greet "World"))
        "greet(World) should be exactly 'Hello, World!'")
(assert (= "Hello, ClojureWasm!" (greet "ClojureWasm"))
        "greet(ClojureWasm) should be exactly 'Hello, ClojureWasm!'")
(assert (= "Hello, !" (greet ""))
        "greet('') should be exactly 'Hello, !'")

(println "PASS: 05_wit_test")
