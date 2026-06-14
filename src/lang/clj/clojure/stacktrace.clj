;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.stacktrace API (originally Stuart Sierra; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.
;;
;; ClojureWasm has no JVM Throwable / StackTraceElement (ADR-0059): a caught
;; exception is an ex-info value read via ex-message / ex-data / ex-cause /
;; class / stack-trace. A CAUGHT exception carries cljw-shaped frames (ADR-0120,
;; deep-copied onto the value); `(stack-trace e)` returns them as
;; `{:ns :fn :file :line :column}` maps (ADR-0140) and per-frame printing renders
;; `<ns>/<fn> (<file>:<line>)` — NOT JVM `class.method` frames (the cljw-native
;; format divergence is the amended AD-029). A NEVER-THROWN ex-info has no
;; frames, so it keeps the honest "[no stack trace available]" marker. Frames are
;; user-only (elided at push time, AD-024). The `*e`-dependent REPL helper `e`
;; (ClojureWasm binds no `*e`) is intentionally NOT provided.

(ns ^{:doc "Print Clojure-centric exception traces (ClojureWasm: cause-chain
            oriented; cljw-shaped per-frame printing, no JVM StackTraceElement)."}
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

(defn print-trace-element
  "Prints one cljw frame map {:ns :fn :file :line} as `<ns>/<fn> (<file>:<line>)`
  (ClojureWasm-native, not JVM class.method — ADR-0140)."
  [{:keys [ns fn file line]}]
  (print (str (when ns (str ns "/")) fn " (" (or file "") ":" line ")")))

(defn print-stack-trace
  "Prints a Clojure-oriented view of tr. A caught exception carries cljw-shaped
  frames (ADR-0120); each is printed as `<ns>/<fn> (<file>:<line>)`. A never-thrown
  ex-info has no frames, so the `[no stack trace available]` marker is printed
  (AD-029). `n`, when positive, limits the number of frames. Does not print
  chained exceptions (causes)."
  ([tr] (print-stack-trace tr nil))
  ([tr n]
   (print-throwable tr)
   (newline)
   (let [st (stack-trace tr)
         st (if (and n (pos? n)) (take n st) st)]
     (if-let [top (first st)]
       (do
         (print " at ")
         (print-trace-element top)
         (doseq [e (rest st)]
           (newline)
           (print "    ")
           (print-trace-element e)))
       (print " at [no stack trace available]")))))

(defn print-cause-trace
  "Like print-stack-trace but also prints the chained exceptions (causes)."
  ([tr] (print-cause-trace tr nil))
  ([tr n]
   (print-stack-trace tr n)
   (when-let [cause (ex-cause tr)]
     (newline)
     (print "Caused by: ")
     (recur cause n))))
