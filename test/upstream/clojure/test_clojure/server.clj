;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/test/clojure/test_clojure/server.clj
;; Upstream lines: 48
;; CLJW markers: 8

; Author: Alex Miller

(ns clojure.test-clojure.server
    ;; CLJW: removed java.util.Random import
  (:require [clojure.test :refer :all])
  (:require [clojure.core.server :as s]))

;; CLJW: JVM interop — validate-opts not implemented in CW (socket server stub)
;; (defn check-invalid-opts [opts msg]
;;   (try
;;     (#'clojure.core.server/validate-opts opts)
;;     (is nil)
;;     (catch Exception e
;;       (is (= (ex-data e) opts))
;;       (is (= msg (.getMessage e))))))

;; CLJW: JVM interop — Thread, System/setProperty, Random not in CW
;; (defn create-random-thread [] ...)

;; CLJW: JVM interop — validate-opts not implemented
;; (deftest test-validate-opts
;;   (check-invalid-opts {} "Missing required socket server property :name")
;;   (check-invalid-opts {:name "a" :accept 'clojure.core/+} "Missing required socket server property :port")
;;   (doseq [port [-1 "5" 999999]]
;;     (check-invalid-opts {:name "a" :port port :accept 'clojure.core/+} (str "Invalid socket server port: " port)))
;;   (check-invalid-opts {:name "a" :port 5555} "Missing required socket server property :accept"))

;; CLJW: JVM interop — System/getProperties, Thread not in CW
;; (deftest test-parse-props
;;   (let [thread (create-random-thread)]
;;     (.start thread)
;;     (Thread/sleep 1000)
;;     (try
;;       (is (>= (count (#'s/parse-props (System/getProperties))) 0))
;;       (finally (.interrupt thread)))))

;; CLJW-ADD: test CW stub API surface
(deftest test-stop-server
  (testing "stop-server/stop-servers don't throw"
    (is (= nil (s/stop-server)))
    (is (= nil (s/stop-server "test")))
    (is (= nil (s/stop-servers)))))

(deftest test-session-var
  (testing "*session* is nil by default"
    (is (= nil s/*session*))))

(deftest test-start-server-throws
  (testing "start-server throws not-implemented"
    (is (thrown? Exception (s/start-server {:name "test" :port 5555})))))

(deftest test-prepl-throws
  (testing "prepl throws not-implemented"
    (is (thrown? Exception (s/prepl nil nil)))))

;; CLJW-ADD: test runner invocation
(run-tests)
