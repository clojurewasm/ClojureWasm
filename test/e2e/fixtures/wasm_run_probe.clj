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

;; :env (D-348) — a string/keyword-keyed map of env vars threads to the guest's
;; WASI environ (zwasm's runner already consumes env_keys/env_vals). The probe
;; module does not echo env, so this asserts the parse + run succeed (exit 0) and
;; that a non-map / non-string-value :env raises a catchable error.
(let [r (wasm/run "test/e2e/fixtures/wasm_run_probe.wasm"
                  {:args ["prog"] :env {"FOO" "bar" :BAZ "qux"}})]
  (assert (= 0 (:exit r)) (str "env run exit was " (:exit r)))
  (println "PASS wasm-run-env"))
(println "env-bad-shape:"
  (try (wasm/run "test/e2e/fixtures/wasm_run_probe.wasm" {:args ["p"] :env [1 2]}) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))
(println "env-bad-val:"
  (try (wasm/run "test/e2e/fixtures/wasm_run_probe.wasm" {:args ["p"] :env {"K" 5}}) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))

;; D-350 amendment: wasm/run caches the compiled module. Every per-call option
;; still applies per call, and a cached run returns what an uncached one does.
(wasm/clear-cache!)
(let [probe "test/e2e/fixtures/wasm_run_probe.wasm"
      cases [["alpha" "one"] ["3" "two"] ["beta" ""]]
      runs (doall (for [[a in] cases]
                    [(wasm/run probe {:args ["prog" a] :stdin in})
                     (wasm/run probe {:args ["prog" a] :stdin in :cache false})]))]
  (doseq [[cached cold] runs]
    (assert (= cached cold) (pr-str cached cold)))
  (assert (= 3 (:exit (first (second runs)))) (pr-str (second runs)))
  (assert (clojure.string/includes? (:out (first (first runs))) "stdin=one"))
  (assert (= 1 (wasm/clear-cache!)) "the cached runs should share one entry")
  (assert (= 0 (wasm/clear-cache!)))
  (println "PASS wasm-run-cache"))
(let [spin "test/e2e/fixtures/wasm_spin.wasm"]
  (assert (= 1 (:exit (wasm/run spin {:fuel 100000}))))
  (assert (= 1 (:exit (wasm/run spin {:fuel 100000}))) "fuel applies to a cached module")
  (wasm/clear-cache!)
  (println "PASS wasm-run-cache-fuel"))
(println "cache-bad-type:"
  (try (wasm/run "test/e2e/fixtures/wasm_run_probe.wasm" {:cache 1}) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))

(println "DONE")
