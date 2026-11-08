;; Every guest language through the cljw FFI, one program.
;; Run from this directory:  cljw polyglot.clj
;;
;; Core modules (C, Zig, Rust without std) go through wasm/load + wasm/call:
;; scalars cross the boundary, arrays live in the guest's linear memory.
;; A WIT component (Rust with wit-bindgen) is required like a namespace, so
;; records, lists, strings and results cross as plain Clojure data.
;; A Go program is a WASI command: wasm/run gives it argv, env and stdin and
;; returns its stdout, stderr and exit code.
(ns polyglot.demo
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io]
            ["./rust-component/typed_payload.wasm" :as tp]))

;; --- C: a kernel over the guest's own buffer -------------------------------
(def k (wasm/load "c/kernel.wasm" {:fuel 1000000 :max-memory-pages 16}))
(def buf (wasm/call k "buf_addr"))
(assert (<= 4 (wasm/call k "buf_cap")))
(wasm/mem-write! k :f64 buf [1.0 2.0 3.0 4.0])
(assert (= 10.0 (wasm/call k "sum_f64" buf 4)))
(assert (= 4 (wasm/call k "scale_f64" buf 4 2.5)))
(assert (= [2.5 5.0 7.5 10.0] (wasm/mem-read k :f64 buf 4)))
(println "PASS c-kernel")

;; --- Zig: scalar exports, no memory traffic --------------------------------
(def z (wasm/load "zig/numeric.wasm"))
(assert (= 6 (wasm/call z "gcd" 48 18)))
(assert (= 1 (wasm/call z "is_prime" 97)))   ; a Zig bool is an i32 on the wire
(assert (= 0 (wasm/call z "is_prime" 91)))
(assert (= 111 (wasm/call z "collatz_steps" 27)))
(println "PASS zig-numeric")

;; --- Rust, no_std: a 401-byte module ---------------------------------------
(def r (wasm/load "rust-core/fib.wasm"))
(assert (= 12586269025 (wasm/call r "fib" 50)))
(assert (= 3 (wasm/call r "popcount" 7)))
(println "PASS rust-core")

;; --- Rust, WIT component: typed data both ways -----------------------------
(assert (= '([input]) (:arglists (meta #'tp/process))))
(assert (= [:ok {:xs [3 4 5 12] :label "data!"}]
           (tp/process {:xs [3 4 5] :label "data"})))
(assert (= [:err "boom: fail"] (tp/process {:xs [] :label "fail"})))
(println "PASS rust-component")

;; --- Go: a WASI command with argv, env, stdin, stdout ----------------------
;; jsonsum.wasm is built on demand (see go/jsonsum.go); skipped when absent.
(if (.exists (io/file "go/jsonsum.wasm"))
  ;; :args is the whole argv, program name first, exactly as a process sees it.
  (let [res (wasm/run "go/jsonsum.wasm" {:args ["jsonsum" "--fast"]
                                          :env {"MODE" "demo"}
                                          :stdin "[1, 2, 3.5]"})
        out (json/read-str (:out res) :key-fn keyword)]
    (assert (= 0 (:exit res)) (pr-str res))
    (assert (= {:n 3 :sum 6.5 :args ["--fast"] :mode "demo"} out) (pr-str out))
    ;; No :dir, so the guest sees no filesystem: a bad stdin is the only way in.
    (let [bad (wasm/run "go/jsonsum.wasm" {:stdin "not json"})]
      (assert (= 2 (:exit bad)) (pr-str bad)))
    (println "PASS go-command"))
  (println "SKIP go-command (go/jsonsum.wasm not built)"))

(println "DONE")
