;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.stacktrace API (originally Stuart Sierra; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.
;;
;; ClojureWasm has no JVM Throwable / StackTraceElement (ADR-0059): a caught
;; exception is an ex-info value read via ex-message / ex-data / ex-cause /
;; class. So the cause-chain operations (root-cause, print-cause-trace) and
;; print-throwable work fully, but PER-FRAME stack printing degrades — the
;; ExInfo carries frame data internally yet exposes no Clojure-level accessor
;; (that surface is owned by the clojure.repl/pst work, D-232). The "[no stack
;; trace available]" marker is the honest degradation, recorded as AD-029.
;; `print-trace-element` (no frame elements to take) and the `*e`-dependent REPL
;; helper `e` (ClojureWasm binds no `*e`) are intentionally NOT provided.

(ns ^{:doc "Print Clojure-centric exception traces (ClojureWasm: cause-chain
            oriented; per-frame printing degrades, no JVM StackTraceElement)."}
  clojure.stacktrace)

(defn root-cause
  "Returns the last 'cause' in a chain of exceptions."
  [tr]
  (if-let [cause (ex-cause tr)]
    (recur cause)
    tr))

(defn print-throwable
  "Prints the class and message of an exception, then its ex-data map if present."
  [tr]
  (print (str (class tr) ": " (ex-message tr)))
  (when-let [info (ex-data tr)]
    (newline)
    (pr info)))

(defn print-stack-trace
  "Prints a Clojure-oriented view of tr. ClojureWasm exposes no Clojure-level
  per-frame accessor for a caught exception (AD-029), so a degradation marker
  replaces the frame list; `n` is accepted for clj-compatibility and ignored.
  Does not print chained exceptions (causes)."
  ([tr] (print-stack-trace tr nil))
  ([tr n]
   (print-throwable tr)
   (newline)
   (print " at [no stack trace available]")))

(defn print-cause-trace
  "Like print-stack-trace but also prints the chained exceptions (causes)."
  ([tr] (print-cause-trace tr nil))
  ([tr n]
   (print-stack-trace tr n)
   (when-let [cause (ex-cause tr)]
     (newline)
     (print "Caused by: ")
     (recur cause n))))
