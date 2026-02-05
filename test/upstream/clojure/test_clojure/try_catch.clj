;; Upstream: clojure/test/clojure/test_clojure/try_catch.clj
;; Upstream lines: 40
;; CLJW markers: 5

;; CLJW: removed (:import [clojure.test ReflectorTryCatchFixture ...]) — JVM interop
(ns clojure.test-clojure.try-catch
  (:use clojure.test))

;; CLJW: JVM interop — get-exception helper uses eval + java.lang.Throwable
;; CLJW: JVM interop — catch-receives-checked-exception-from-eval (java.io.FileReader, FileNotFoundException)
;; CLJW: JVM interop — catch-receives-checked-exception-from-reflective-call (ReflectorTryCatchFixture)

;; CLJW-ADD: portable try/catch/finally tests using ex-info/throw
(deftest try-returns-body-value
  (is (= 42 (try 42)))
  (is (= :ok (try :ok)))
  (is (nil? (try nil))))

(deftest try-catch-basic
  (is (= "caught"
         (try (throw (ex-info "error" {}))
              (catch Exception e "caught"))))
  (is (= {:msg "test" :data {:a 1}}
         (try (throw (ex-info "test" {:a 1}))
              (catch Exception e
                {:msg (ex-message e) :data (ex-data e)})))))

(deftest try-catch-no-exception
  (is (= 42 (try 42 (catch Exception e :nope))))
  (is (= "ok" (try "ok" (catch Exception e :nope)))))

(deftest try-finally-basic
  (let [a (atom :not-run)]
    (is (= 42 (try 42 (finally (reset! a :run)))))
    (is (= :run @a))))

(deftest try-finally-on-exception
  (let [a (atom :not-run)]
    (is (= "caught"
           (try (throw (ex-info "x" {}))
                (catch Exception e "caught")
                (finally (reset! a :run)))))
    (is (= :run @a))))

(deftest try-finally-propagates-exception
  (let [a (atom :not-run)]
    (is (thrown? Exception
                 (try (throw (ex-info "propagated" {}))
                      (finally (reset! a :run)))))
    (is (= :run @a))))

(deftest try-nested
  (is (= "inner"
         (try
           (try (throw (ex-info "inner" {}))
                (catch Exception e "inner"))
           (catch Exception e "outer"))))
  (is (= "outer"
         (try
           (try (throw (ex-info "x" {})))
           (catch Exception e "outer")))))

(deftest try-catch-runtime-errors
  (is (thrown? Exception (/ 1 0)))
  (is (thrown? Exception (nth [1 2 3] 10)))
  (is (= "ok"
         (try (/ 1 0)
              (catch Exception e "ok")))))

;; CLJW-ADD: test runner invocation
(run-tests)
