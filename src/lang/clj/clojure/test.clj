;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.test API (originally Stuart Sierra and contributors; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.test — assertion + test-runner surface (D-227, ADR-0083-unblocked).
;;
;; Loaded by `bootstrap.zig::loadCore` after core.clj (so defmacro / syntax-quote
;; / defmulti / atom / *ns* / ns-name / clojure.walk are all available). The
;; (in-ns) header is mandatory — the loader carries no namespace knowledge.
;;
;; Design (per the D-227 Devil's-advocate fork): a PER-NAMESPACE test registry
;; keyed by the test ns symbol (so `(run-tests 'foo.test)` — the call external
;; runners make — works), `is` as a macro routing through an `assert-expr`
;; multimethod (`=` / `thrown?` / default), a `report` multimethod keyed on
;; `:type`, and `*report-counters*` as a dynamic var holding an atom.
;;
;; cljw adaptations (no JVM): vars carry no source location, so the FAIL/ERROR
;; line omits clj's ` (file:line)` suffix and `report :error` cannot print a JVM
;; cause trace — both are AD-041. Deferred: per-var lifecycle events
;; (begin/end-test-var, end-test-ns), use-fixtures, with-test.

(ns clojure.test (:refer-clojure))

;; ---------------------------------------------------------------------------
;; State: report counters (dynamic, an atom) + the per-ns registry.
;; ---------------------------------------------------------------------------
(def ^:dynamic *report-counters* nil)
(def *initial-report-counters* {:test 0 :pass 0 :fail 0 :error 0})
(def ^:dynamic *testing-contexts* (list))
;; The Var(s) of the test currently running (test-var binds it) — lets a
;; reporter name the failing test. clj-compat surface (D-273/D-232).
(def ^:dynamic *testing-vars* (list))
;; Stack-trace depth a reporter may pass to clojure.stacktrace (nil = full).
(def ^:dynamic *stack-trace-depth* nil)

;; Where report output goes. clj binds this to the load-time *out*; `with-test-out`
;; rebinds *out* to it so `(binding [*test-out* w] (run-tests))` redirects output.
;; cljw's *out* works (with-out-str), so this is re-enabled (was a no-JVM deferral).
(def ^:dynamic *test-out* *out*)

;; ns-name-symbol -> vector of test Vars (deftest appends; run-tests reads).
(def *test-registry* (atom {}))

;; ---------------------------------------------------------------------------
;; report multimethod (keyed on :type) + do-report. `^:dynamic` so an
;; alternate reporter (e.g. clojure.test.tap) can `(binding [report …] …)`.
;; ---------------------------------------------------------------------------
(defmulti ^:dynamic report :type)

(defn inc-report [k]
  (when *report-counters*
    (swap! *report-counters* update k (fn [n] (inc (or n 0))))))

;; clj-compat alias: clojure.test/inc-report-counter is the public name a
;; reporter calls; cljw's internal counter bump is `inc-report`.
(def inc-report-counter inc-report)

;; clj-compat: run body with *out* bound to *test-out* (so a reporter's output
;; is redirectable by binding *test-out*).
(defmacro with-test-out [& body]
  `(binding [*out* *test-out*] ~@body))

;; A string naming the test(s) currently running, for a reporter's pass/fail
;; line: the simple test name(s) in a list, e.g. "(my-test)" (clj form, minus
;; the ` (file:line)` suffix — cljw has no source location on Vars, AD-041).
(defn testing-vars-str [_m]
  (str "(" (clojure.string/join " " (reverse (map #(:name (meta %)) *testing-vars*))) ")"))

;; A string of the active `testing` context strings (outermost first).
(defn testing-contexts-str []
  (clojure.string/join " " (reverse *testing-contexts*)))

(defn print-contexts []
  (when (seq *testing-contexts*)
    (println (testing-contexts-str))))

(defmethod report :pass [m] (with-test-out (inc-report :pass)))

(defmethod report :fail [m]
  (with-test-out
    (inc-report :fail)
    (println)
    (println "FAIL in" (testing-vars-str m))
    (print-contexts)
    (when (:message m) (println (:message m)))
    (println "expected:" (pr-str (:expected m)))
    (println "  actual:" (pr-str (:actual m)))))

(defmethod report :error [m]
  (with-test-out
    (inc-report :error)
    (println)
    (println "ERROR in" (testing-vars-str m))
    (print-contexts)
    (when (:message m) (println (:message m)))
    (println "expected:" (pr-str (:expected m)))
    (println "  actual:" (pr-str (:actual m)))))

(defmethod report :begin-test-ns [m]
  (with-test-out
    (println)
    (println "Testing" (:ns m))))

(defmethod report :summary [m]
  (with-test-out
    (println)
    (println "Ran" (:test m) "tests containing"
             (+ (:pass m) (:fail m) (:error m)) "assertions.")
    (println (:fail m) "failures," (:error m) "errors.")))

(defmethod report :default [m] nil)

(defn do-report [m] (report m))

(defn file-position
  "Returns a vector [filename line-number] for the nth call up the stack.
  Deprecated in clj 1.2 (its info now lives on the result map's :file/:line).
  cljw carries no source location on Vars (AD-041) and no JVM stack-frame
  file/line, so this honestly returns [\"NO_SOURCE_FILE\" 0] — kept so code that
  calls it (clojure.test.junit) loads + runs."
  [_n]
  ["NO_SOURCE_FILE" 0])

;; ---------------------------------------------------------------------------
;; assert-expr multimethod — keyed on (first form), called at macroexpand time
;; by `is`. Returns the code that evaluates the assertion + reports.
;; ---------------------------------------------------------------------------
(defmulti assert-expr (fn [msg form] (if (seq? form) (first form) :default)))

;; clj-compat: is `x` a symbol naming a (non-macro) function? Drives the :default
;; split below — a predicate call gets the (not …) actual treatment, anything
;; else (a value, a macro form) just reports the evaluated value.
(defn function? [x]
  (and (symbol? x)
       (when-let [v (resolve x)]
         (and (not (:macro (meta v))) (fn? (deref v))))))

;; Generic. A predicate form like (pos? -1) reports actual (not (pos? -1)) — the
;; evaluated form wrapped in (not …) on fail, the bare form on pass (clj parity).
;; Anything else (a bare value, a macro form) reports the evaluated value.
(defmethod assert-expr :default [msg form]
  (if (and (seq? form) (function? (first form)))
    (let [pred (first form)]
      `(let [args# (list ~@(rest form))
             result# (apply ~pred args#)]
         (if result#
           (do-report {:type :pass :message ~msg :expected (quote ~form) :actual (cons (quote ~pred) args#)})
           (do-report {:type :fail :message ~msg :expected (quote ~form) :actual (list (quote ~'not) (cons (quote ~pred) args#))}))
         result#))
    `(let [value# ~form]
       (if value#
         (do-report {:type :pass :message ~msg :expected (quote ~form) :actual value#})
         (do-report {:type :fail :message ~msg :expected (quote ~form) :actual value#}))
       value#)))

;; (is (= expected actual …)) — on fail, actual shows the evaluated form wrapped
;; in (not …), e.g. (not (= 1 2)); on pass, the evaluated form (= 1 1). The pred
;; symbol is taken from the user's form so it renders bare (= …), not qualified.
(defmethod assert-expr (quote =) [msg form]
  (let [pred (first form)]
    `(let [args# (list ~@(rest form))
           result# (apply = args#)]
       (if result#
         (do-report {:type :pass :message ~msg :expected (quote ~form) :actual (cons (quote ~pred) args#)})
         (do-report {:type :fail :message ~msg :expected (quote ~form) :actual (list (quote ~'not) (cons (quote ~pred) args#))}))
       result#)))

;; (is (thrown? Class body…)) — passes iff body throws an instance of Class;
;; returns the caught exception.
(defmethod assert-expr (quote thrown?) [msg form]
  (let [klass (second form)
        body (nthnext form 2)]
    `(try ~@body
          (do-report {:type :fail :message ~msg :expected (quote ~form) :actual nil})
          (catch ~klass e#
            (do-report {:type :pass :message ~msg :expected (quote ~form) :actual e#})
            e#))))

;; (is (thrown-with-msg? Class regex body…)) — like thrown?, but also requires
;; the thrown exception's message to match `regex` (re-find).
(defmethod assert-expr (quote thrown-with-msg?) [msg form]
  (let [klass (nth form 1)
        re (nth form 2)
        body (nthnext form 3)]
    `(try ~@body
          (do-report {:type :fail :message ~msg :expected (quote ~form) :actual nil})
          (catch ~klass e#
            (if (re-find ~re (ex-message e#))
              (do-report {:type :pass :message ~msg :expected (quote ~form) :actual e#})
              (do-report {:type :fail :message ~msg :expected (quote ~form) :actual e#}))
            e#))))

;; ---------------------------------------------------------------------------
;; is / are / testing.
;; ---------------------------------------------------------------------------
(defmacro try-expr [msg form]
  `(try ~(assert-expr msg form)
        (catch Throwable t#
          (do-report {:type :error :message ~msg :expected (quote ~form) :actual t#})
          nil)))

(defmacro is [form & more]
  `(try-expr ~(first more) ~form))

;; (are [a b] (= a b) 1 1, 2 2) — expands to one (is …) per argv-sized group,
;; substituting the argv symbols with each group's values (no clojure.template
;; dependency; direct postwalk substitution).
(defmacro are [argv expr & args]
  (cons (quote do)
        (map (fn [vals]
               (clojure.walk/postwalk-replace (zipmap argv vals)
                                               (list (quote clojure.test/is) expr)))
             (partition (count argv) args))))

(defmacro testing [s & body]
  `(binding [*testing-contexts* (cons ~s *testing-contexts*)]
     ~@body))

;; ---------------------------------------------------------------------------
;; deftest + the registry + run-tests.
;; ---------------------------------------------------------------------------
(defmacro deftest [name & body]
  `(do
     (def ~name (fn [] ~@body))
     (swap! *test-registry* update (ns-name *ns*)
            (fn [v#] (conj (or v# []) (var ~name))))
     (var ~name)))

(defn test-var [v]
  (when v
    (binding [*testing-vars* (conj *testing-vars* v)]
      ;; Emit the per-var report events (clj parity) so a reporter that wraps
      ;; each test — clojure.test.junit's <testcase>, custom reporters — fires.
      (do-report {:type :begin-test-var :var v})
      ((deref v))
      (do-report {:type :end-test-var :var v}))))

(defn run-tests [& ns-syms]
  (let [targets (if (seq ns-syms) ns-syms (list (ns-name *ns*)))]
    (binding [*report-counters* (atom *initial-report-counters*)]
      (doseq [ns-sym targets]
        (do-report {:type :begin-test-ns :ns ns-sym})
        (doseq [v (get (deref *test-registry*) ns-sym)]
          (swap! *report-counters* update :test inc)
          (test-var v))
        ;; clj parity: emit :end-test-ns so a reporter that brackets a namespace
        ;; (junit's </testsuite>, custom reporters) fires.
        (do-report {:type :end-test-ns :ns ns-sym}))
      (let [summary (assoc (deref *report-counters*) :type :summary)]
        (do-report summary)
        summary))))

(defn run-all-tests []
  (apply run-tests (keys (deref *test-registry*))))
