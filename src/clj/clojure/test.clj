;; clojure.test — minimal test framework for ClojureWasm
;;
;; Provides: deftest, is, testing, run-tests, are, thrown?
;; Based on the inline framework from SCI core_test.clj

;; ========== Test state management ==========

;; Test registry: vector of {:name "test-name" :fn test-fn}
(def test-registry (atom []))
;; Pass counter
(def pass-count (atom 0))
;; Fail counter
(def fail-count (atom 0))
;; Error counter
(def error-count (atom 0))
;; Testing context stack
(def testing-contexts (atom []))

;; ========== Helper functions ==========

;; Join collection elements with separator.
(defn- join-str [sep coll]
  (loop [s (seq coll) acc "" started false]
    (if s
      (if started
        (recur (next s) (str acc sep (first s)) true)
        (recur (next s) (str acc (first s)) true))
      acc)))

;; Record a passing assertion.
(defn- do-report-pass []
  (swap! pass-count inc)
  true)

;; Record a failing assertion and print context.
(defn- do-report-fail [expr msg]
  (swap! fail-count inc)
  (println (str "  FAIL in " (join-str " > " @testing-contexts)))
  (when msg (println (str "    message: " msg)))
  (println (str "    expected: " expr))
  false)

;; Record a failing thrown? assertion (no exception was thrown).
(defn- do-report-fail-thrown [expr msg]
  (swap! fail-count inc)
  (println (str "  FAIL in " (join-str " > " @testing-contexts)))
  (when msg (println (str "    message: " msg)))
  (println (str "    expected exception in: " expr))
  nil)

;; ========== Core assertion ==========

;; Internal assertion handler.
(defn- do-is [result expr-str msg]
  (if result
    (do-report-pass)
    (do-report-fail expr-str msg)))

;; ========== Context management ==========

;; Push a testing context onto the stack.
(defn- push-context [desc]
  (swap! testing-contexts conj desc))

;; Pop a testing context from the stack.
(defn- pop-context []
  (swap! testing-contexts pop))

;; Execute body-fn within a named testing context.
(defn- do-testing [desc body-fn]
  (push-context desc)
  (try
    (body-fn)
    (finally
      (pop-context))))

;; ========== Test registration ==========

;; Register a test function with its name.
(defn- register-test [name test-fn]
  (swap! test-registry conj {:name name :fn test-fn}))

;; ========== Public macros ==========

;; Define a test function. The test will be registered for run-tests.
(defmacro deftest [tname & body]
  `(do
     (defn ~tname [] ~@body)
     (register-test ~(str tname) ~tname)))

;; Assert macro with pattern dispatch.
;; (is expr), (is expr msg)
;; (is (thrown? ExType body...))
;; (is (thrown-with-msg? ExType re body...))
(defmacro is [& args]
  (let [expr (first args)
        msg (second args)]
    (cond
      (and (seq? expr) (= (first expr) 'thrown?))
      ;; thrown? dispatch: try body, catch expected class
      (let [klass (second expr)
            body (rest (rest expr))]
        `(try
           (do ~@body)
           (do-report-fail-thrown ~(str expr) ~msg)
           (catch ~klass e#
             (do-report-pass)
             e#)))

      (and (seq? expr) (= (first expr) 'thrown-with-msg?))
      ;; thrown-with-msg? dispatch: catch + message regex match
      (let [klass (second expr)
            re (nth expr 2)
            body (rest (rest (rest expr)))]
        `(try
           (do ~@body)
           (do-report-fail-thrown ~(str expr) ~msg)
           (catch ~klass e#
             (if (re-find ~re (str e#))
               (do (do-report-pass) e#)
               (do (do-report-fail ~(str expr) ~msg) e#)))))

      :else
      ;; default: evaluate and check truthiness
      `(do-is ~expr ~(str expr) ~msg))))

;; Group assertions under a descriptive string.
(defmacro testing [desc & body]
  `(do-testing ~desc (fn [] ~@body)))

;; Check multiple assertions with a template expression.
;; Example: (are [x y] (= x y) 2 (+ 1 1) 4 (* 2 2))
;; Expands to: (do (is (= 2 (+ 1 1))) (is (= 4 (* 2 2))))
(defmacro are [argv expr & args]
  (let [c (count argv)
        groups (partition c args)]
    `(do ~@(map (fn [g] `(is ~(postwalk-replace (zipmap argv g) expr))) groups))))

;; Assert that body throws an exception of the given class.
;; Usage: (is (thrown? Exception (/ 1 0)))
;; UPSTREAM-DIFF: standalone macro (upstream uses assert-expr multimethod in is)
(defmacro thrown? [klass & body]
  `(try
     (do ~@body)
     false
     (catch ~klass ~'e true)))

;; ========== Test runner ==========

;; Run all registered tests. Returns true if all tests pass.
(defn run-tests []
  ;; Reset counters
  (reset! pass-count 0)
  (reset! fail-count 0)
  (reset! error-count 0)

  ;; Run each test
  (let [tests @test-registry]
    (doseq [t tests]
      (reset! testing-contexts [(:name t)])
      (println (str "\nTesting " (:name t)))
      (try
        ((:fn t))
        (catch Exception e
          (swap! error-count inc)
          (println (str "  ERROR in " (:name t) ": " e)))))

    ;; Print summary
    (println "")
    (let [total (+ @pass-count @fail-count @error-count)]
      (println (str "Ran " (count tests) " tests containing " total " assertions"))
      (println (str @pass-count " passed, " @fail-count " failed, " @error-count " errors")))

    ;; Return success status
    (let [total-problems (+ @fail-count @error-count)]
      (if (= 0 total-problems)
        (println "ALL TESTS PASSED")
        (println (str total-problems " problem(s) found")))
      (= 0 total-problems))))
