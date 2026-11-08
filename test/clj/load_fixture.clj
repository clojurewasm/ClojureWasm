;; Fixture for suites.io-test/load-file-reads-and-evals: loaded via load-file.
;; NOT a suite (not under suites/, not *_test.clj), so run_suites never runs it.
;; Bare defs land in whatever ns is current when load-file evaluates the forms;
;; the final form is a value so load-file's last-form return can be asserted.
(def load-file-fixture-val 42)
(def load-file-fixture-marker :loaded)
(def load-file-fixture-file *file*)
(* load-file-fixture-val 2)
