;; clojure.test — test framework for ClojureWasm
;;
;; UPSTREAM-DIFF: uses atom-based counters/registry instead of ref-based report-counters
;; UPSTREAM-DIFF: report is a dynamic fn (not multimethod)
;; UPSTREAM-DIFF: do-report does not add file/line info (no StackTraceElement)
;; UPSTREAM-DIFF: deftest uses register-test atom (not ns metadata)
;; UPSTREAM-DIFF: run-tests uses atom registry (not ns-based test-ns)

;; ========== Test state management ==========

;; Test registry: vector of {:name "test-name" :var var :fn test-fn}
(def test-registry (atom []))
;; Assertion counters
(def pass-count (atom 0))
(def fail-count (atom 0))
(def error-count (atom 0))
;; Test counter (incremented per test-var call)
(def test-count (atom 0))

;; UPSTREAM-DIFF: *report-counters* aliases atom-based counters for API compat
(def ^:dynamic *initial-report-counters* {:test 0, :pass 0, :fail 0, :error 0})

;; UPSTREAM-DIFF: not a ref, just returns current atom snapshot
(def ^:dynamic *report-counters* nil)

;; Testing context stack (for nested testing blocks)
(def ^:dynamic *testing-contexts* (list))
;; Testing vars stack (for nested test-var calls)
(def ^:dynamic *testing-vars* (list))
;; Output stream for test reporting
(def ^:dynamic *test-out* *out*)
;; Stack trace depth for error reporting
(def ^:dynamic *stack-trace-depth* nil)
;; Whether to load tests (when false, deftest/set-test are no-ops)
(def ^:dynamic *load-tests* true)

;; ========== Output ==========

;; Runs body with *out* bound to the value of *test-out*.
(defmacro with-test-out [& body]
  `(binding [*out* *test-out*]
     ~@body))

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

;; Testing vars string for error messages.
(defn testing-vars-str
  "Returns a string representation of the current test var context."
  {:added "1.1"}
  [m]
  (let [v (:var m)]
    (if v
      (let [md (meta v)]
        (str (:name md) " (" (:ns md) ")"))
      "")))

;; UPSTREAM-DIFF: inc-report-counter uses atoms instead of dosync/commute on ref
(defn inc-report-counter
  "Increments the named counter in the test counters."
  {:added "1.1"}
  [name]
  (cond
    (= name :pass) (swap! pass-count inc)
    (= name :fail) (swap! fail-count inc)
    (= name :error) (swap! error-count inc)
    (= name :test) (swap! test-count inc)))

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

;; UPSTREAM-DIFF: does not add file/line info (no StackTraceElement)
(defn do-report
  "Call report, intended for use in custom assertion methods."
  {:added "1.2"}
  [m]
  (clojure.test/report m))

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
  (when *load-tests*
    `(do
       (defn ~tname [] ~@body)
       (alter-meta! (var ~tname) assoc :test ~tname :name ~(str tname))
       (register-test ~(str tname) ~tname (var ~tname)))))

;; Like deftest but creates a private var.
(defmacro deftest- [tname & body]
  (when *load-tests*
    `(do
       (defn ~tname [] ~@body)
       (alter-meta! (var ~tname) assoc :test ~tname :name ~(str tname) :private true)
       (register-test ~(str tname) ~tname (var ~tname)))))

;; Sets :test metadata of the named var to a fn with the given body.
(defmacro set-test [tname & body]
  (when *load-tests*
    `(alter-meta! (var ~tname) assoc :test (fn [] ~@body))))

;; Adds test to an existing var. Creates var if needed.
(defmacro with-test [definition & body]
  (when *load-tests*
    `(do ~definition
         (alter-meta! (var ~(second definition)) assoc :test (fn [] ~@body)))))

;; Run a single test var. Calls report with :begin-test-var/:end-test-var.
(defn test-var [v]
  (when-let [t (:test (meta v))]
    (swap! test-count inc)
    (binding [*testing-vars* (conj *testing-vars* v)]
      (clojure.test/report {:type :begin-test-var :var v})
      (try
        (t)
        (catch Exception e
          (clojure.test/report {:type :error
                                :message "Uncaught exception, not in assertion."
                                :expected nil
                                :actual e})))
      (clojure.test/report {:type :end-test-var :var v}))))

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

    ;; Return summary map (upstream compat)
    {:test @test-count :pass @pass-count :fail @fail-count :error @error-count}))

(defn successful?
  "Returns true if the given test summary indicates all tests
  were successful, false otherwise."
  {:added "1.1"}
  [summary]
  (and (zero? (:fail summary 0))
       (zero? (:error summary 0))))

;; Run all tests in all namespaces. Optional regex filters namespace names.
(defn run-all-tests
  "Runs all tests in all namespaces; prints results.
  Optional argument is a regular expression; only namespaces with
  names matching the regular expression (with re-matches) will be
  tested."
  {:added "1.1"}
  ([] (run-tests))
  ([re]
   ;; UPSTREAM-DIFF: CW uses atom registry, so just run-tests (no ns filtering)
   ;; All registered tests run regardless of ns filter
   (run-tests)))

;; Run tests for a single var, with fixtures and summary output.
(defn run-test-var
  "Runs the tests for a single Var, with fixtures executed around the
  test, and summary output after."
  {:added "1.11"}
  [v]
  ;; Reset counters
  (reset! pass-count 0)
  (reset! fail-count 0)
  (reset! error-count 0)
  (reset! test-count 0)
  ;; Run single var through test-vars for fixture support
  (test-vars [v])
  ;; Report summary
  (let [summary {:type :summary
                 :test @test-count
                 :pass @pass-count
                 :fail @fail-count
                 :error @error-count}]
    (clojure.test/report summary)
    (dissoc summary :type)))

;; Run a single test by symbol name.
;; UPSTREAM-DIFF: macro in upstream, fn here (resolve works at runtime)
(defn run-test
  "Runs a single test. Resolves the symbol to a var and runs it."
  {:added "1.11"}
  [test-symbol]
  (if-let [v (resolve test-symbol)]
    (if (:test (meta v))
      (run-test-var v)
      (println (str test-symbol " is not a test.")))
    (println (str "Unable to resolve " test-symbol " to a test function."))))

;; Returns true if argument is a function or a symbol that resolves to
;; a function (not a macro).
(defn function?
  "Returns true if argument is a function or a symbol that resolves to
  a function (not a macro)."
  {:added "1.1"}
  [x]
  (if (symbol? x)
    (when-let [v (resolve x)]
      (when-let [value (deref v)]
        (and (fn? value)
             (not (:macro (meta v))))))
    (fn? x)))
