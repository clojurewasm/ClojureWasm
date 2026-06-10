;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.test.tap API (originally Stuart Sierra;
;; Clojure, EPL-1.0) for ClojureWasm; no upstream source text is reproduced.
;;
;; TAP (Test Anything Protocol) output for clojure.test. Wrap a run-tests call in
;; `with-tap-output` to rebind `clojure.test/report` to the TAP reporter:
;;   (with-tap-output (run-tests 'my.lib))
;; ClojureWasm adaptations (no JVM): `.split` → clojure.string/split-lines; the
;; exception check uses cljw's `Throwable` host marker (an ex-info IS a Throwable).

(ns clojure.test.tap
  (:require [clojure.test :as t]
            [clojure.stacktrace :as stack]
            [clojure.string :as str]))

(defn print-tap-plan
  "Prints a TAP plan line `1..n` (n = number of tests)."
  [n]
  (println (str "1.." n)))

(defn print-tap-diagnostic
  "Prints a TAP diagnostic line per line of `data` (a possibly multi-line string)."
  [data]
  (doseq [line (str/split-lines data)]
    (println "#" line)))

(defn print-tap-pass
  "Prints a TAP `ok` line. `msg` has no line breaks."
  [msg]
  (println "ok" msg))

(defn print-tap-fail
  "Prints a TAP `not ok` line. `msg` has no line breaks."
  [msg]
  (println "not ok" msg))

(defmulti ^:dynamic tap-report :type)

(defmethod tap-report :default [data]
  (t/with-test-out
    (print-tap-diagnostic (pr-str data))))

(defn print-diagnostics [data]
  (when (seq t/*testing-contexts*)
    (print-tap-diagnostic (t/testing-contexts-str)))
  (when (:message data)
    (print-tap-diagnostic (:message data)))
  (print-tap-diagnostic (str "expected:" (pr-str (:expected data))))
  (if (= :pass (:type data))
    (print-tap-diagnostic (str "  actual:" (pr-str (:actual data))))
    (print-tap-diagnostic
     (str "  actual:"
          (with-out-str
            (if (instance? Throwable (:actual data))
              (stack/print-cause-trace (:actual data) t/*stack-trace-depth*)
              (prn (:actual data))))))))

(defmethod tap-report :pass [data]
  (t/with-test-out
    (t/inc-report-counter :pass)
    (print-tap-pass (t/testing-vars-str data))
    (print-diagnostics data)))

(defmethod tap-report :error [data]
  (t/with-test-out
    (t/inc-report-counter :error)
    (print-tap-fail (t/testing-vars-str data))
    (print-diagnostics data)))

(defmethod tap-report :fail [data]
  (t/with-test-out
    (t/inc-report-counter :fail)
    (print-tap-fail (t/testing-vars-str data))
    (print-diagnostics data)))

(defmethod tap-report :summary [data]
  (t/with-test-out
    (print-tap-plan (+ (:pass data) (:fail data) (:error data)))))

(defmacro with-tap-output
  "Execute body with clojure.test/report rebound to produce TAP output."
  [& body]
  `(binding [t/report tap-report]
     ~@body))
