;; test/clj/run_suites.clj — the cljw-NATIVE test runner (Layer 5b).
;;
;; WHY THIS EXISTS. The bash e2e tier (`test/e2e/*.sh`) pays one cljw PROCESS
;; SPAWN per assertion: 425 scripts issue 3,016 `cljw -e '…'` invocations, and
;; a spawn costs ~21 ms, so ~63 s of a gate run is process startup that proves
;; nothing. A clojure.test suite run BY cljw pays that once for the whole file.
;; Measured 2026-08-29 on the same coverage (key/val + select-keys):
;; two bash scripts (18 spawns) = 401 ms; the equivalent suite (21 assertions,
;; 1 process) = 47 ms — 8.5x, and the suite asserts MORE.
;;
;; It is also the fast inner loop: over an nREPL the deftests re-run on
;; redefine with NO rebuild, which the bash tier can never do. `dev/user.clj`
;; is that loop, and it discovers suites through the same `harness.suites` this
;; file uses, so the two tiers cannot disagree about what a suite is.
;;
;; WHAT STAYS IN BASH. Layer 2 is the CLI surface — process exit codes, stderr
;; rendering, argv handling. A suite running INSIDE cljw cannot assert its own
;; exit code, so those stay `test/e2e/*.sh`. Everything that is really "evaluate
;; an expression, check the value (or that it throws)" belongs here.
;;
;; DISCOVERY, NOT REGISTRATION. Suites are found by listing `test/clj/suites/`,
;; so a new suite file runs the moment it exists. An explicit suite list would
;; reproduce the coverage-lie that `scripts/check_e2e_reach.sh` exists to catch
;; (a test written but never wired up gates nothing). A file that FAILS to load
;; is reported and fails the run — it is never silently skipped.
;;
;; This file is the BOUNDARY: the process-level report and the exit code. The
;; discovery rule itself is `harness.suites`.
;;
;; Usage:  cljw -cp test/clj test/clj/run_suites.clj
;; Optional args select discovered namespace(s), e.g. suites.lazy-seqable-gc-test.
;; Namespace selectors require -M, which supplies *command-line-args*:
;; cljw -cp test/clj -M test/clj/run_suites.clj suites.lazy-seqable-gc-test
(require '[clojure.test :as test]
         '[harness.suites :as suites])

(let [{:keys [files missing]} (suites/select-files (suites/files) *command-line-args*)
      {:keys [ok failed]} (suites/load-all! files)]
  (when (seq missing)
    (println (str "\nUnknown suite namespaces: " missing)))
  (when (seq failed)
    (println "\nSUITES THAT FAILED TO LOAD:")
    (doseq [[f err] failed] (println (str "  " f " -> " err))))
  (when (empty? files)
    (println (str "\nNo suites selected under " suites/dir "/")))
  (let [r (when (seq ok) (apply test/run-tests ok))
        bad (+ (long (or (:fail r) 0)) (long (or (:error r) 0)))]
    (println (str "\nsuites: " (count ok) " loaded, " (count failed) " failed to load"))
    (System/exit (if (and (seq files) (empty? missing) (zero? bad) (empty? failed)) 0 1))))
