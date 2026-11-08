;; test/e2e/phase15_proxy_threadlocal.sh
;;
;; clojure.core/proxy over the REGISTERED proxyable base classes (D-298).
;; cljw has no JVM class hierarchy to extend, so `proxy` is closed per build:
;; ThreadLocal is entry 1, realized as a memoized one-slot cell in cljw.proxy
;; (single-threaded wasm — .get runs initialValue once then caches; .set
;; overwrites; .remove clears so the next .get re-inits). An unregistered base
;; is a compile-time error, not a deep JVM class extension.
;;
;; This is the blocker-2 gate for clojure.test.check.random on cljw, which is
;; the generator engine malli.generator (and every schema property suite) needs.

;; Migrated from test/e2e/phase15_proxy_threadlocal.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.proxy-threadlocal-test
  (:require [clojure.test :refer [deftest is]]))

(deftest proxy-threadlocal-cases
  (is (= "42" (pr-str (let [tl (proxy [ThreadLocal] [] (initialValue [] 42))] (.get tl)))) "proxy_tl_initialValue")
  (is (= "[1 1 1]" (pr-str (let [c (atom 0) tl (proxy [ThreadLocal] [] (initialValue [] (swap! c inc)))] [(.get tl) (.get tl) @c]))) "proxy_tl_caches_initialValue")
  (is (= "9" (pr-str (let [tl (proxy [ThreadLocal] [] (initialValue [] 1))] (.set tl 9) (.get tl)))) "proxy_tl_set")
  (is (= "[1 2 2]" (pr-str (let [c (atom 0) tl (proxy [ThreadLocal] [] (initialValue [] (swap! c inc)))] [(.get tl) (do (.remove tl) (.get tl)) @c]))) "proxy_tl_remove_reinits")
  (is (= ":ok" (pr-str (let [tl (proxy [java.lang.ThreadLocal] [] (initialValue [] :ok))] (.get tl)))) "proxy_tl_fqcn")
  (is (= "[1 10]" (pr-str (let [a (atom 0) tl (proxy [ThreadLocal] [] (initialValue [] (swap! a inc) @a))] (let [v (.get tl)] (.set tl (* 10 v)) [v (.get tl)])))) "proxy_tl_random_pattern")
  (is (= ":caught" (pr-str (try (macroexpand (quote (proxy [Runnable] [] (run [] 1)))) :no-throw (catch Throwable e (if (re-find #"not part of ClojureWasm" (str (ex-message e))) :caught :wrong-msg))))) "proxy_unregistered_base_throws"))
