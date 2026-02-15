;; clojure.test — test framework for ClojureWasm
;;
;; UPSTREAM-DIFF: *report-counters* uses atom instead of ref (no STM)
;; UPSTREAM-DIFF: do-report does not add file/line info (no StackTraceElement)
;; UPSTREAM-DIFF: deftest uses register-test atom (not ns metadata)

;; ========== Test state management ==========

;; Test registry: vector of {:name "test-name" :var var :fn test-fn}
(def test-registry (atom []))
(def ^:dynamic *initial-report-counters* {:test 0, :pass 0, :fail 0, :error 0})

;; UPSTREAM-DIFF: atom instead of ref (no STM needed, single-threaded reporting)
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

(defn inc-report-counter
  "Increments the named counter in *report-counters*, a ref of a map.
  Does nothing if *report-counters* is nil."
  {:added "1.1"}
  [name]
  (when *report-counters*
    (swap! *report-counters* update name (fnil inc 0))))

;; Multimethod report — dispatches on (:type m).
(defmulti report :type)

(defmethod report :default [m]
  (with-test-out (prn m)))

(defmethod report :pass [m]
  (with-test-out (inc-report-counter :pass)))

(defmethod report :fail [m]
  (with-test-out
    (inc-report-counter :fail)
    (println "\nFAIL in" (testing-vars-str m))
    (when (seq *testing-contexts*) (println (testing-contexts-str)))
    (when-let [message (:message m)] (println message))
    (println "expected:" (pr-str (:expected m)))
    (println "  actual:" (pr-str (:actual m)))))

(defmethod report :error [m]
  (with-test-out
    (inc-report-counter :error)
    (println "\nERROR in" (testing-vars-str m))
    (when (seq *testing-contexts*) (println (testing-contexts-str)))
    (when-let [message (:message m)] (println message))
    (println "expected:" (pr-str (:expected m)))
    (println "  actual:" (pr-str (:actual m)))))

(defmethod report :summary [m]
  (with-test-out
    (println "\nRan" (:test m) "tests containing"
             (+ (:pass m) (:fail m) (:error m)) "assertions.")
    (println (:fail m) "failures," (:error m) "errors.")))

(defmethod report :begin-test-ns [m]
  (with-test-out
    (println "\nTesting" (ns-name (:ns m)))))

(defmethod report :end-test-ns [m])
(defmethod report :begin-test-var [m])
(defmethod report :end-test-var [m])

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

;; Register a test function with its name, var, and namespace.
(defn- register-test [name test-fn test-var]
  (swap! test-registry conj {:name name :fn test-fn :var test-var :ns (ns-name *ns*)}))

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
    (inc-report-counter :test)
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

(defn test-ns
  "If the namespace defines a function named test-ns-hook, calls that.
  Otherwise, calls test-all-vars on the namespace. 'ns' is a namespace
  object or a symbol. Returns a map of test result counts."
  {:added "1.1"}
  [ns]
  (let [ns-obj (the-ns ns)
        counters (atom *initial-report-counters*)]
    (binding [*report-counters* counters]
      (do-report {:type :begin-test-ns :ns ns-obj})
      (if-let [v (find-var (symbol (str (ns-name ns-obj)) "test-ns-hook"))]
        ((var-get v))
        (test-all-vars ns-obj))
      (do-report {:type :end-test-ns :ns ns-obj}))
    @counters))

(defn get-possibly-unbound-var
  "Like var-get but returns nil if the var is unbound."
  {:added "1.1"}
  [v]
  (try (var-get v)
       (catch Exception e nil)))

;; ========== Assertion helpers ==========

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

;; Returns generic assertion code for any functional predicate.
(defn assert-predicate
  "Returns generic assertion code for any functional predicate.  The
  'expected' argument to 'report' will contains the original form, the
  'actual' argument will contain the form with all its sub-forms
  evaluated.  If the predicate returns false, the 'actual' form will
  be wrapped in (not...)."
  {:added "1.1"}
  [msg form]
  (let [args (rest form)
        pred (first form)]
    `(let [values# (list ~@args)
           result# (apply ~pred values#)]
       (if result#
         (do-report {:type :pass, :message ~msg,
                     :expected '~form, :actual (cons '~pred values#)})
         (do-report {:type :fail, :message ~msg,
                     :expected '~form, :actual (list '~'not (cons '~pred values#))}))
       result#)))

;; Returns generic assertion code for any test.
(defn assert-any
  "Returns generic assertion code for any test, including macros, Java
  method calls, or isolated symbols."
  {:added "1.1"}
  [msg form]
  `(let [value# ~form]
     (if value#
       (do-report {:type :pass, :message ~msg,
                   :expected '~form, :actual value#})
       (do-report {:type :fail, :message ~msg,
                   :expected '~form, :actual value#}))
     value#))

;; ========== assert-expr multimethod ==========

;; Multimethod for assertion expression expansion.
;; Dispatches on (first form) for seq forms, :always-fail for nil, :default otherwise.
(defmulti assert-expr
  (fn [msg form]
    (cond
      (nil? form) :always-fail
      (seq? form) (first form)
      :else :default)))

(defmethod assert-expr :always-fail [msg form]
  `(do-report {:type :fail, :message ~msg}))

(defmethod assert-expr :default [msg form]
  (if (and (sequential? form) (function? (first form)))
    (assert-predicate msg form)
    (assert-any msg form)))

(defmethod assert-expr 'instance? [msg form]
  `(let [klass# ~(nth form 1)
         object# ~(nth form 2)]
     (let [result# (instance? klass# object#)]
       (if result#
         (do-report {:type :pass, :message ~msg,
                     :expected '~form, :actual (type object#)})
         (do-report {:type :fail, :message ~msg,
                     :expected '~form, :actual (type object#)}))
       result#)))

(defmethod assert-expr 'thrown? [msg form]
  (let [klass (second form)
        body (nthnext form 2)]
    `(try ~@body
          (do-report {:type :fail, :message ~msg,
                      :expected '~form, :actual nil})
          (catch ~klass e#
            (do-report {:type :pass, :message ~msg,
                        :expected '~form, :actual e#})
            e#))))

;; UPSTREAM-DIFF: uses (str e#) instead of (.getMessage e#) for exception message
(defmethod assert-expr 'thrown-with-msg? [msg form]
  (let [klass (nth form 1)
        re (nth form 2)
        body (nthnext form 3)]
    `(try ~@body
          (do-report {:type :fail, :message ~msg, :expected '~form, :actual nil})
          (catch ~klass e#
            (let [m# (str e#)]
              (if (re-find ~re m#)
                (do-report {:type :pass, :message ~msg,
                            :expected '~form, :actual e#})
                (do-report {:type :fail, :message ~msg,
                            :expected '~form, :actual e#})))
            e#))))

;; ========== Assertion macros ==========

;; UPSTREAM-DIFF: catches Exception instead of Throwable
(defmacro try-expr
  "Used by the 'is' macro to catch unexpected exceptions.
  You don't call this."
  {:added "1.1"}
  [msg form]
  `(try ~(assert-expr msg form)
        (catch Exception t#
          (do-report {:type :error, :message ~msg,
                      :expected '~form, :actual t#}))))

(defmacro is
  "Generic assertion macro.  'form' is any predicate test.
  'msg' is an optional message to attach to the assertion."
  {:added "1.1"}
  ([form] `(is ~form nil))
  ([form msg] `(try-expr ~msg ~form)))

;; Group assertions under a descriptive string.
(defmacro testing [desc & body]
  `(do-testing ~desc (fn [] ~@body)))

;; Check multiple assertions with a template expression.
;; Example: (are [x y] (= x y) 2 (+ 1 1) 4 (* 2 2))
(defmacro are [argv expr & args]
  (let [c (count argv)
        groups (partition c args)]
    `(do ~@(map (fn [g] `(is ~(postwalk-replace (zipmap argv g) expr))) groups))))

;; Assert that body throws an exception of the given class (standalone utility).
(defmacro thrown? [klass & body]
  `(try
     (do ~@body)
     false
     (catch ~klass ~'e true)))

;; ========== Test runner ==========

;; Run all registered tests with fixtures. Returns true if all pass.
;; If the current namespace defines test-ns-hook, calls it instead.
(defn run-tests
  "Runs all tests in the given namespaces; prints results.
  Defaults to current namespace if none given. Returns a map
  summarizing test results."
  {:added "1.1"}
  ([] (run-tests *ns*))
  ([& namespaces]
   (let [summary (assoc (apply merge-with + (map test-ns namespaces))
                        :type :summary)]
     (do-report summary)
     summary)))

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
  ([] (apply run-tests (distinct (map :ns @test-registry))))
  ([re]
   (apply run-tests (filter #(re-matches re (str %))
                            (distinct (map :ns @test-registry))))))

;; Run tests for a single var, with fixtures and summary output.
(defn run-test-var
  "Runs the tests for a single Var, with fixtures executed around the
  test, and summary output after."
  {:added "1.11"}
  [v]
  (let [counters (atom *initial-report-counters*)]
    (binding [*report-counters* counters]
      (test-vars [v])
      (let [summary (assoc @counters :type :summary)]
        (do-report summary)
        (dissoc summary :type)))))

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

