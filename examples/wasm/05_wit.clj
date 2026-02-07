;; 05_wit.clj — WIT-powered string auto-marshalling
;; Run: ./zig-out/bin/cljw examples/wasm/05_wit.clj

;; ============================================================
;; Part 1: Load with WIT for high-level type info
;; ============================================================

(def greet-mod (wasm/load "src/wasm/testdata/10_greet.wasm"
                          {:wit "src/wasm/testdata/10_greet.wit"}))

;; WIT describes functions at a higher level than Wasm core types
(println "WIT describe:" (wasm/describe greet-mod))
;; => {"greet" {:params [{:name "name" :type :string}] :results :string}}

;; Compare with core-level exports
(println "Core exports:" (wasm/exports greet-mod))
;; => {"greet" {:params [:i32 :i32] :results [:i32 :i32]}}

;; ============================================================
;; Part 2: String auto-marshalling
;; ============================================================

;; With WIT, string params are automatically marshalled:
;; 1. Clojure string → UTF-8 bytes
;; 2. cabi_realloc allocates Wasm memory
;; 3. Bytes written to linear memory
;; 4. (ptr, len) pair passed as i32 args
;; 5. Result (ptr, len) read back as Clojure string

(def greet (wasm/fn greet-mod "greet"))
(println (greet "World"))          ;; => Hello, World!
(println (greet "Clojure"))        ;; => Hello, Clojure!
(println (greet "WebAssembly"))    ;; => Hello, WebAssembly!

;; ============================================================
;; Part 3: Keyword lookup with WIT marshalling
;; ============================================================

;; WIT info propagates to keyword-dispatched functions too
(println ((:greet greet-mod) "CW"))    ;; => Hello, CW!

;; Map over names
(println (map (:greet greet-mod) ["Alice" "Bob" "Charlie"]))
;; => ("Hello, Alice!" "Hello, Bob!" "Hello, Charlie!")

(println "05_wit done.")
