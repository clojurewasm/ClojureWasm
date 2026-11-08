;; test/e2e/phase14_thread_runtime.sh — D-425 singleton host objects.
;; Thread/currentThread + .getName and Runtime/getRuntime + .availableProcessors.
;; Both return a process-lifetime host_instance SINGLETON (cached on rt), so
;; identity holds across calls (clj-faithful). cljw runs user code on one thread
;; (name "main"); availableProcessors reports the host CPU count.

;; Migrated from test/e2e/phase14_thread_runtime.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.thread-runtime-test
  (:require [clojure.test :refer [deftest is]]))

(deftest thread-runtime-cases
  (is (= "\"main\"" (pr-str (.getName (Thread/currentThread)))) "thread_name")
  (is (= "\"main\"" (pr-str (.getName (java.lang.Thread/currentThread)))) "thread_name_fqcn")
  (is (= "true" (pr-str (identical? (Thread/currentThread) (Thread/currentThread)))) "thread_singleton")
  (is (= "true" (pr-str (pos? (.availableProcessors (Runtime/getRuntime))))) "rt_procs_pos")
  (is (= "true" (pr-str (integer? (.availableProcessors (Runtime/getRuntime))))) "rt_procs_int")
  (is (= "true" (pr-str (identical? (Runtime/getRuntime) (Runtime/getRuntime)))) "rt_singleton"))

;; test.check's failure reporter walks (.getStackTrace (Thread/currentThread))
;; for file and line. cljw has no StackTraceElement (ADR-0059), so the member
;; answers an empty array and the reporter takes its empty-trace branch.
(deftest thread-get-stack-trace-is-empty
  (let [st (.getStackTrace (Thread/currentThread))]
    (is (some? st) "stack_trace_present")
    (is (= 0 (alength st)) "stack_trace_empty")
    (is (nil? (seq st)) "stack_trace_seq_nil")))
