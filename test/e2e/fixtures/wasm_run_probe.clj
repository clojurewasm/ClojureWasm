;; e2e for (wasm/run …) — run a WASI command (Rust wasm32-wasip1) and capture
;; stdout / stderr / exit. The fixture wasm prints its user args (argv[1..]),
;; echoes stdin, writes one stderr line, and exits with the code named by its
;; first USER arg (argv[1]) — argv[0] is the program name by convention.
(let [r (wasm/run "test/e2e/fixtures/wasm_run_probe.wasm"
                  {:args ["prog" "alpha" "beta"] :stdin "hello-from-clojure"})]
  (assert (= 0 (:exit r)) (str "exit was " (:exit r)))
  (assert (clojure.string/includes? (:out r) "args=alpha,beta") (pr-str (:out r)))
  (assert (clojure.string/includes? (:out r) "stdin=hello-from-clojure") (pr-str (:out r)))
  (assert (clojure.string/includes? (:err r) "diag-on-stderr") (pr-str (:err r)))
  (println "PASS wasm-run-basic"))

;; A non-zero exit is returned as data, NOT raised. argv[1] = "7" → exit 7.
(let [r (wasm/run "test/e2e/fixtures/wasm_run_probe.wasm" {:args ["prog" "7"]})]
  (assert (= 7 (:exit r)) (str "expected exit 7, got " (:exit r)))
  (println "PASS wasm-run-exit-code"))

;; Failure paths are catchable cljw exceptions (not exit-70 crashes).
(println "bad-path-or-jail:"
  (try (wasm/run "../../../../etc/nope.wasm") "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))
(println "bad-arg-type:"
  (try (wasm/run 42) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))

(println "DONE")
