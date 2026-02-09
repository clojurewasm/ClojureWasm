;; clojure.test — test framework for ClojureWasm
;;
;; Provides: deftest, is, testing, run-tests, are, thrown?,
;;           use-fixtures, test-var, test-vars, test-all-vars, report
;; UPSTREAM-DIFF: uses atom-based counters/registry instead of ref-based report-counters

;; ========== Test state management ==========

;; Test registry: vector of {:name "test-name" :var var :fn test-fn}
(def test-registry (atom []))
;; Assertion counters
(def pass-count (atom 0))
(def fail-count (atom 0))
(def error-count (atom 0))
;; Test counter (incremented per test-var call)
(def test-count (atom 0))
;; Testing context stack (for nested testing blocks)
(def ^:dynamic *testing-contexts* (list))

;; ========== Reporting ==========

;; Join collection elements with separator.
(defn- join-str [sep coll]
  (loop [s (seq coll) acc "" started false]
    (if s
      (if started
        (recur (next s) (str acc sep (first s)) true)
        (recur (next s) (str acc (first s)) true))
      acc)))

;; Testing context string for error messages.
(defn testing-contexts-str []
  (join-str " > " (reverse *testing-contexts*)))

;; Default report function — dispatches on (:type m).
(defn- default-report [m]
  (let [event (:type m)]
    (cond
      (= event :pass)
      (swap! pass-count inc)

      (= event :fail)
      (do
        (swap! fail-count inc)
        (println (str "  FAIL in " (testing-contexts-str)))
        (when (:message m)
          (println (str "    message: " (:message m))))
        (println (str "    expected: " (:expected m)))
        (when (contains? m :actual)
          (println (str "    actual: " (:actual m)))))

      (= event :error)
      (do
        (swap! error-count inc)
        (println (str "  ERROR in " (testing-contexts-str)))
        (when (:message m)
          (println (str "    message: " (:message m))))
        (println (str "    expected: " (:expected m)))
        (when (contains? m :actual)
          (println (str "    actual: " (:actual m)))))

      (= event :begin-test-var)
      (println (str "\nTesting " (:name (meta (:var m)))))

      (= event :end-test-var) nil

      (= event :begin-test-ns)
      nil

      (= event :end-test-ns) nil

      (= event :summary)
      (do
        (println "")
        (let [total (+ (:pass m 0) (:fail m 0) (:error m 0))]
          (println (str "Ran " (:test m 0) " tests containing " total " assertions"))
          (println (str (:pass m 0) " passed, " (:fail m 0) " failed, " (:error m 0) " errors"))
          (if (= 0 (+ (:fail m 0) (:error m 0)))
            (println "ALL TESTS PASSED")
            (println (str (+ (:fail m 0) (:error m 0)) " problem(s) found")))))

      :else nil)))

;; Dynamic report var — can be rebound for custom test reporting.
(def ^:dynamic report default-report)

;; ========== Context management ==========

;; Execute body-fn within a named testing context.
(defn- do-testing [desc body-fn]
  (binding [*testing-contexts* (conj *testing-contexts* desc)]
    (body-fn)))

;; ========== Fixtures ==========

;; Fixture registry: {ns-name-str {:once [fns] :each [fns]}}
(def ^:private fixtures-registry (atom {}))

;; Compose two fixture functions into one.
(defn compose-fixtures [f1 f2]
  (fn [g] (f1 (fn [] (f2 g)))))

;; Compose a collection of fixtures. Returns identity fixture if empty.
(defn join-fixtures [fixtures]
  (if (seq fixtures)
    (reduce compose-fixtures fixtures)
    (fn [f] (f))))

;; Register fixtures for the current namespace.
;; (use-fixtures :once f1 f2) — wraps entire test run
;; (use-fixtures :each f1 f2) — wraps each individual test
(defn use-fixtures [fixture-type & fns]
  (let [ns-name (str (ns-name *ns*))
        key (if (= fixture-type :once) :once :each)]
    (swap! fixtures-registry assoc-in [ns-name key] (vec fns))))

;; ========== Test registration and running ==========

;; Register a test function with its name and var.
(defn- register-test [name test-fn test-var]
  (swap! test-registry conj {:name name :fn test-fn :var test-var}))

;; Define a test function. Registers it and adds :test metadata to the var.
(defmacro deftest [tname & body]
  `(do
     (defn ~tname [] ~@body)
     (alter-meta! (var ~tname) assoc :test ~tname :name ~(str tname))
     (register-test ~(str tname) ~tname (var ~tname))))

;; Run a single test var. Calls report with :begin-test-var/:end-test-var.
(defn test-var [v]
  (when-let [t (:test (meta v))]
    (swap! test-count inc)
    (clojure.test/report {:type :begin-test-var :var v})
    (try
      (t)
      (catch Exception e
        (clojure.test/report {:type :error
                              :message "Uncaught exception, not in assertion."
                              :expected nil
                              :actual e})))
    (clojure.test/report {:type :end-test-var :var v})))

;; Run test vars grouped by namespace with fixtures applied.
(defn test-vars [vars]
  (let [groups (group-by (fn [v] (or (:ns (meta v)) *ns*)) vars)]
    (doseq [[ns vs] groups]
      (let [ns-name (str (if (symbol? ns) ns (ns-name ns)))
            fixtures (get @fixtures-registry ns-name)
            once-fixture-fn (join-fixtures (:once fixtures))
            each-fixture-fn (join-fixtures (:each fixtures))]
        (once-fixture-fn
         (fn []
           (doseq [v vs]
             (when (:test (meta v))
               (each-fixture-fn (fn [] (test-var v)))))))))))

;; Run all test vars in a namespace.
(defn test-all-vars [ns]
  (test-vars (vals (ns-interns ns))))

;; ========== Assertion macros ==========

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
           (clojure.test/report {:type :fail :message ~msg
                                 :expected '~expr :actual nil})
           nil
           (catch ~klass e#
             (clojure.test/report {:type :pass :message ~msg
                                   :expected '~expr :actual e#})
             e#)))

      (and (seq? expr) (= (first expr) 'thrown-with-msg?))
      ;; thrown-with-msg? dispatch: catch + message regex match
      (let [klass (second expr)
            re (nth expr 2)
            body (rest (rest (rest expr)))]
        `(try
           (do ~@body)
           (clojure.test/report {:type :fail :message ~msg
                                 :expected '~expr :actual nil})
           nil
           (catch ~klass e#
             (if (re-find ~re (str e#))
               (do (clojure.test/report {:type :pass :message ~msg
                                         :expected '~expr :actual e#})
                   e#)
               (do (clojure.test/report {:type :fail :message ~msg
                                         :expected '~expr :actual e#})
                   e#)))))

      :else
      ;; default: evaluate and check truthiness
      `(let [result# ~expr]
         (if result#
           (do (clojure.test/report {:type :pass :message ~msg
                                     :expected '~expr :actual result#})
               true)
           (do (clojure.test/report {:type :fail :message ~msg
                                     :expected '~expr :actual result#})
               false))))))

;; Group assertions under a descriptive string.
(defmacro testing [desc & body]
  `(do-testing ~desc (fn [] ~@body)))

;; Check multiple assertions with a template expression.
;; Example: (are [x y] (= x y) 2 (+ 1 1) 4 (* 2 2))
(defmacro are [argv expr & args]
  (let [c (count argv)
        groups (partition c args)]
    `(do ~@(map (fn [g] `(is ~(postwalk-replace (zipmap argv g) expr))) groups))))

;; Assert that body throws an exception of the given class.
;; UPSTREAM-DIFF: standalone macro (upstream uses assert-expr multimethod in is)
(defmacro thrown? [klass & body]
  `(try
     (do ~@body)
     false
     (catch ~klass ~'e true)))

;; ========== Test runner ==========

;; Run all registered tests with fixtures. Returns true if all pass.
(defn run-tests []
  ;; Reset counters
  (reset! pass-count 0)
  (reset! fail-count 0)
  (reset! error-count 0)
  (reset! test-count 0)

  ;; Collect test vars from registry
  (let [tests @test-registry
        vars (map :var tests)]
    ;; Run through test-vars to apply fixtures
    (if (seq vars)
      (test-vars vars)
      ;; Fallback: run directly if no vars registered (shouldn't happen)
      (doseq [t tests]
        (binding [*testing-contexts* (list (:name t))]
          (println (str "\nTesting " (:name t)))
          (try
            ((:fn t))
            (catch Exception e
              (swap! error-count inc)
              (println (str "  ERROR in " (:name t) ": " e)))))))

    ;; Print summary via report
    (clojure.test/report {:type :summary
                          :test @test-count
                          :pass @pass-count
                          :fail @fail-count
                          :error @error-count})

    ;; Return success status
    (= 0 (+ @fail-count @error-count))))
