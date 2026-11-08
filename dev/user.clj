;; dev/user.clj — the REPL-driven scratchpad.
;;
;; `user` is the namespace a Clojure REPL starts in, so everything here is
;; reachable the moment a REPL comes up with `dev` on the classpath:
;;
;;     zig-out/bin/cljw nrepl --port 7899 -cp src:test:test/clj:dev
;;     bb scripts/dev_repl.clj eval '(user/run-all)'
;;
;; Nothing in this file is loaded by the gate, and nothing the gate depends on
;; may be DEFINED here — `dev/` is scratch, `test/` is the contract. The
;; discovery rule is deliberately not re-implemented below; it is required from
;; `harness.suites`, the same namespace `test/clj/run_suites.clj` runs on, so a
;; suite cannot pass here and be invisible to the gate.
;;
;; WHY A WARM IMAGE AT ALL. Measured 2026-08-30 (quiet machine, warm cache):
;; redefining a var over nREPL costs 0.13 s, the same change through core.clj
;; costs ~400 s (full bytecode regen), and a .zig change costs ~400-590 s. So
;; the loop is: work out WHAT a definition should be here, where a `defn` in
;; the running image shadows the embedded one, then edit the real file and pay
;; the rebuild ONCE.
;;
;; The suites themselves do NOT need this image — cljw cold-starts in ~21 ms,
;; which beats a warm round trip. Reach for `run-all` when you are iterating on
;; a definition, not when you just want the tier green.
(ns user
  (:require [clojure.test :as test]
            [harness.suites :as suites]))

(defn suite-names
  "Every discovered suite namespace, as data. Reads the directory; runs nothing."
  []
  (suites/namespaces))

(defn run-all
  "Load and run the whole cljw-native suite tier in this image.

  Returns clojure.test's summary map rather than exiting, which is what makes
  it usable from a REPL at all — `run_suites.clj` is the projection that turns
  the same result into a process exit code."
  []
  (let [{:keys [ok failed]} (suites/load-all!)]
    (when (seq failed)
      (println "SUITES THAT FAILED TO LOAD:")
      (doseq [[f err] failed] (println (str "  " f " -> " err))))
    (apply test/run-tests ok)))

(defn run-suite
  "Reload one suite from source and run just it.

  `:reload` is the point: without it a redefined deftest keeps the definition
  the image already has, and the run reports the OLD assertions as green."
  [suite-ns]
  (require suite-ns :reload)
  (test/run-tests suite-ns))

(comment
  ;; --- the tier -----------------------------------------------------------
  (suite-names)
  (run-all)
  (run-suite 'suites.bigdecimal-test)

  ;; --- one assertion at a time --------------------------------------------
  ;; The fastest loop is not a test at all: evaluate the expression, look at
  ;; the value, and only then decide what the assertion should say.
  (str (.setScale (bigdec "2.5") 0 BigDecimal/ROUND_HALF_EVEN))
  (pr-str (biginteger 5))

  ;; --- shadowing a core definition ----------------------------------------
  ;; A `defn` here replaces the embedded one for THIS image only. Use it to
  ;; settle on a definition, then move it into src/lang/clj/clojure/core.clj
  ;; and rebuild once.
  (defn my-candidate [x] (inc x))
  (my-candidate 1)

  ;; --- differential probing against the clj oracle ------------------------
  ;; Bound every sequence producer with (take N …) before it reaches either
  ;; runtime; an unbounded seq pins a core and an uncapped JVM eats the box.
  ;; The harness is scripts/clj_diff_sweep.clj — do not hand-roll the loop.
  (take 5 (map inc (range)))
  )
