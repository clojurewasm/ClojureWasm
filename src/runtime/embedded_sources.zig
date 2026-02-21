// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Embedded Clojure source strings for library namespaces.
//!
//! Extracted from bootstrap.zig (Phase R1.2). Each constant is either a Zig
//! multiline string or an @embedFile reference. Used by bootstrap.zig loadXxx()
//! functions and vmRecompileAll().

/// Embedded core.clj source (compiled into binary).
pub const core_clj_source = @embedFile("../clj/clojure/core.clj");

// test.clj replaced with Zig multiline string (Phase B.14)
// No Zig builtins — entire test framework stays as evalString due to heavy macro/multimethod usage.
pub const test_clj_source =
    \\(def test-registry (atom []))
    \\(def ^:dynamic *initial-report-counters* {:test 0, :pass 0, :fail 0, :error 0})
    \\(def ^:dynamic *report-counters* nil)
    \\(def ^:dynamic *testing-contexts* (list))
    \\(def ^:dynamic *testing-vars* (list))
    \\(def ^:dynamic *test-out* *out*)
    \\(def ^:dynamic *stack-trace-depth* nil)
    \\(def ^:dynamic *load-tests* true)
    \\(defmacro with-test-out [& body]
    \\  `(binding [*out* *test-out*]
    \\     ~@body))
    \\(defn- join-str [sep coll]
    \\  (loop [s (seq coll) acc "" started false]
    \\    (if s
    \\      (if started
    \\        (recur (next s) (str acc sep (first s)) true)
    \\        (recur (next s) (str acc (first s)) true))
    \\      acc)))
    \\(defn testing-contexts-str []
    \\  (join-str " > " (reverse *testing-contexts*)))
    \\(defn testing-vars-str
    \\  {:added "1.1"}
    \\  [m]
    \\  (let [v (:var m)]
    \\    (if v
    \\      (let [md (meta v)]
    \\        (str (:name md) " (" (:ns md) ")"))
    \\      "")))
    \\(defn inc-report-counter
    \\  {:added "1.1"}
    \\  [name]
    \\  (when *report-counters*
    \\    (swap! *report-counters* update name (fnil inc 0))))
    \\(defmulti report :type)
    \\(defmethod report :default [m]
    \\  (with-test-out (prn m)))
    \\(defmethod report :pass [m]
    \\  (with-test-out (inc-report-counter :pass)))
    \\(defmethod report :fail [m]
    \\  (with-test-out
    \\    (inc-report-counter :fail)
    \\    (println "\nFAIL in" (testing-vars-str m))
    \\    (when (seq *testing-contexts*) (println (testing-contexts-str)))
    \\    (when-let [message (:message m)] (println message))
    \\    (println "expected:" (pr-str (:expected m)))
    \\    (println "  actual:" (pr-str (:actual m)))))
    \\(defmethod report :error [m]
    \\  (with-test-out
    \\    (inc-report-counter :error)
    \\    (println "\nERROR in" (testing-vars-str m))
    \\    (when (seq *testing-contexts*) (println (testing-contexts-str)))
    \\    (when-let [message (:message m)] (println message))
    \\    (println "expected:" (pr-str (:expected m)))
    \\    (println "  actual:" (pr-str (:actual m)))))
    \\(defmethod report :summary [m]
    \\  (with-test-out
    \\    (println "\nRan" (:test m) "tests containing"
    \\             (+ (:pass m) (:fail m) (:error m)) "assertions.")
    \\    (println (:fail m) "failures," (:error m) "errors.")))
    \\(defmethod report :begin-test-ns [m]
    \\  (with-test-out
    \\    (println "\nTesting" (ns-name (:ns m)))))
    \\(defmethod report :end-test-ns [m])
    \\(defmethod report :begin-test-var [m])
    \\(defmethod report :end-test-var [m])
    \\(defn do-report
    \\  {:added "1.2"}
    \\  [m]
    \\  (clojure.test/report m))
    \\(defn- do-testing [desc body-fn]
    \\  (binding [*testing-contexts* (conj *testing-contexts* desc)]
    \\    (body-fn)))
    \\(def ^:private fixtures-registry (atom {}))
    \\(defn compose-fixtures [f1 f2]
    \\  (fn [g] (f1 (fn [] (f2 g)))))
    \\(defn join-fixtures [fixtures]
    \\  (if (seq fixtures)
    \\    (reduce compose-fixtures fixtures)
    \\    (fn [f] (f))))
    \\(defn use-fixtures [fixture-type & fns]
    \\  (let [ns-name (str (ns-name *ns*))
    \\        key (if (= fixture-type :once) :once :each)]
    \\    (swap! fixtures-registry assoc-in [ns-name key] (vec fns))))
    \\(defn- register-test [name test-fn test-var]
    \\  (swap! test-registry conj {:name name :fn test-fn :var test-var :ns (ns-name *ns*)}))
    \\(defmacro deftest [tname & body]
    \\  (when *load-tests*
    \\    `(do
    \\       (defn ~tname [] ~@body)
    \\       (alter-meta! (var ~tname) assoc :test ~tname :name ~(str tname))
    \\       (register-test ~(str tname) ~tname (var ~tname)))))
    \\(defmacro deftest- [tname & body]
    \\  (when *load-tests*
    \\    `(do
    \\       (defn ~tname [] ~@body)
    \\       (alter-meta! (var ~tname) assoc :test ~tname :name ~(str tname) :private true)
    \\       (register-test ~(str tname) ~tname (var ~tname)))))
    \\(defmacro set-test [tname & body]
    \\  (when *load-tests*
    \\    `(alter-meta! (var ~tname) assoc :test (fn [] ~@body))))
    \\(defmacro with-test [definition & body]
    \\  (when *load-tests*
    \\    `(do ~definition
    \\         (alter-meta! (var ~(second definition)) assoc :test (fn [] ~@body)))))
    \\(defn test-var [v]
    \\  (when-let [t (:test (meta v))]
    \\    (inc-report-counter :test)
    \\    (binding [*testing-vars* (conj *testing-vars* v)]
    \\      (clojure.test/report {:type :begin-test-var :var v})
    \\      (try
    \\        (t)
    \\        (catch Exception e
    \\          (clojure.test/report {:type :error
    \\                                :message "Uncaught exception, not in assertion."
    \\                                :expected nil
    \\                                :actual e})))
    \\      (clojure.test/report {:type :end-test-var :var v}))))
    \\(defn test-vars [vars]
    \\  (let [groups (group-by (fn [v] (or (:ns (meta v)) *ns*)) vars)]
    \\    (doseq [[ns vs] groups]
    \\      (let [ns-name (str (if (symbol? ns) ns (ns-name ns)))
    \\            fixtures (get @fixtures-registry ns-name)
    \\            once-fixture-fn (join-fixtures (:once fixtures))
    \\            each-fixture-fn (join-fixtures (:each fixtures))]
    \\        (once-fixture-fn
    \\         (fn []
    \\           (doseq [v vs]
    \\             (when (:test (meta v))
    \\               (each-fixture-fn (fn [] (test-var v)))))))))))
    \\(defn test-all-vars [ns]
    \\  (test-vars (vals (ns-interns ns))))
    \\(defn test-ns
    \\  {:added "1.1"}
    \\  [ns]
    \\  (let [ns-obj (the-ns ns)
    \\        counters (atom *initial-report-counters*)]
    \\    (binding [*report-counters* counters]
    \\      (do-report {:type :begin-test-ns :ns ns-obj})
    \\      (if-let [v (find-var (symbol (str (ns-name ns-obj)) "test-ns-hook"))]
    \\        ((var-get v))
    \\        (test-all-vars ns-obj))
    \\      (do-report {:type :end-test-ns :ns ns-obj}))
    \\    @counters))
    \\(defn get-possibly-unbound-var
    \\  {:added "1.1"}
    \\  [v]
    \\  (try (var-get v)
    \\       (catch Exception e nil)))
    \\(defn function?
    \\  {:added "1.1"}
    \\  [x]
    \\  (if (symbol? x)
    \\    (when-let [v (resolve x)]
    \\      (when-let [value (deref v)]
    \\        (and (fn? value)
    \\             (not (:macro (meta v))))))
    \\    (fn? x)))
    \\(defn assert-predicate
    \\  {:added "1.1"}
    \\  [msg form]
    \\  (let [args (rest form)
    \\        pred (first form)]
    \\    `(let [values# (list ~@args)
    \\           result# (apply ~pred values#)]
    \\       (if result#
    \\         (do-report {:type :pass, :message ~msg,
    \\                     :expected '~form, :actual (cons '~pred values#)})
    \\         (do-report {:type :fail, :message ~msg,
    \\                     :expected '~form, :actual (list '~'not (cons '~pred values#))}))
    \\       result#)))
    \\(defn assert-any
    \\  {:added "1.1"}
    \\  [msg form]
    \\  `(let [value# ~form]
    \\     (if value#
    \\       (do-report {:type :pass, :message ~msg,
    \\                   :expected '~form, :actual value#})
    \\       (do-report {:type :fail, :message ~msg,
    \\                   :expected '~form, :actual value#}))
    \\     value#))
    \\(defmulti assert-expr
    \\  (fn [msg form]
    \\    (cond
    \\      (nil? form) :always-fail
    \\      (seq? form) (first form)
    \\      :else :default)))
    \\(defmethod assert-expr :always-fail [msg form]
    \\  `(do-report {:type :fail, :message ~msg}))
    \\(defmethod assert-expr :default [msg form]
    \\  (if (and (sequential? form) (function? (first form)))
    \\    (assert-predicate msg form)
    \\    (assert-any msg form)))
    \\(defmethod assert-expr 'instance? [msg form]
    \\  `(let [klass# ~(nth form 1)
    \\         object# ~(nth form 2)]
    \\     (let [result# (instance? klass# object#)]
    \\       (if result#
    \\         (do-report {:type :pass, :message ~msg,
    \\                     :expected '~form, :actual (type object#)})
    \\         (do-report {:type :fail, :message ~msg,
    \\                     :expected '~form, :actual (type object#)}))
    \\       result#)))
    \\(defmethod assert-expr 'thrown? [msg form]
    \\  (let [klass (second form)
    \\        body (nthnext form 2)]
    \\    `(try ~@body
    \\          (do-report {:type :fail, :message ~msg,
    \\                      :expected '~form, :actual nil})
    \\          (catch ~klass e#
    \\            (do-report {:type :pass, :message ~msg,
    \\                        :expected '~form, :actual e#})
    \\            e#))))
    \\(defmethod assert-expr 'thrown-with-msg? [msg form]
    \\  (let [klass (nth form 1)
    \\        re (nth form 2)
    \\        body (nthnext form 3)]
    \\    `(try ~@body
    \\          (do-report {:type :fail, :message ~msg, :expected '~form, :actual nil})
    \\          (catch ~klass e#
    \\            (let [m# (str e#)]
    \\              (if (re-find ~re m#)
    \\                (do-report {:type :pass, :message ~msg,
    \\                            :expected '~form, :actual e#})
    \\                (do-report {:type :fail, :message ~msg,
    \\                            :expected '~form, :actual e#})))
    \\            e#))))
    \\(defmacro try-expr
    \\  {:added "1.1"}
    \\  [msg form]
    \\  `(try ~(assert-expr msg form)
    \\        (catch Exception t#
    \\          (do-report {:type :error, :message ~msg,
    \\                      :expected '~form, :actual t#}))))
    \\(defmacro is
    \\  {:added "1.1"}
    \\  ([form] `(is ~form nil))
    \\  ([form msg] `(try-expr ~msg ~form)))
    \\(defmacro testing [desc & body]
    \\  `(do-testing ~desc (fn [] ~@body)))
    \\(defmacro are [argv expr & args]
    \\  (let [c (count argv)
    \\        groups (partition c args)]
    \\    `(do ~@(map (fn [g] `(is ~(postwalk-replace (zipmap argv g) expr))) groups))))
    \\(defmacro thrown? [klass & body]
    \\  `(try
    \\     (do ~@body)
    \\     false
    \\     (catch ~klass ~'e true)))
    \\(defn run-tests
    \\  {:added "1.1"}
    \\  ([] (run-tests *ns*))
    \\  ([& namespaces]
    \\   (let [summary (assoc (apply merge-with + (map test-ns namespaces))
    \\                        :type :summary)]
    \\     (do-report summary)
    \\     summary)))
    \\(defn successful?
    \\  {:added "1.1"}
    \\  [summary]
    \\  (and (zero? (:fail summary 0))
    \\       (zero? (:error summary 0))))
    \\(defn run-all-tests
    \\  {:added "1.1"}
    \\  ([] (apply run-tests (distinct (map :ns @test-registry))))
    \\  ([re]
    \\   (apply run-tests (filter #(re-matches re (str %))
    \\                            (distinct (map :ns @test-registry))))))
    \\(defn run-test-var
    \\  {:added "1.11"}
    \\  [v]
    \\  (let [counters (atom *initial-report-counters*)]
    \\    (binding [*report-counters* counters]
    \\      (test-vars [v])
    \\      (let [summary (assoc @counters :type :summary)]
    \\        (do-report summary)
    \\        (dissoc summary :type)))))
    \\(defn run-test
    \\  {:added "1.11"}
    \\  [test-symbol]
    \\  (if-let [v (resolve test-symbol)]
    \\    (if (:test (meta v))
    \\      (run-test-var v)
    \\      (println (str test-symbol " is not a test.")))
    \\    (println (str "Unable to resolve " test-symbol " to a test function."))))
;

// walk.clj removed — now Zig builtins in ns_walk.zig (Phase B.4)

// set.clj removed — now Zig builtins in ns_set.zig (Phase B.6)

/// Embedded clojure/data.clj source (compiled into binary).
// data.clj removed — now Zig builtins in ns_data.zig (Phase B.5)

// repl.clj functions removed — now Zig builtins in ns_repl.zig (Phase B.10)
// Only macros (doc, dir, source) and special-doc-map remain as evalString.
pub const repl_macros_source =
    \\(def ^:private special-doc-map
    \\  '{def {:forms [(def symbol doc-string? init?)]
    \\         :doc "Creates and interns a global var with the name
    \\  of symbol in the current namespace (*ns*) or locates such a var if
    \\  it already exists.  If init is supplied, it is evaluated, and the
    \\  root binding of the var is set to the resulting value.  If init is
    \\  not supplied, the root binding of the var is unaffected."}
    \\    do {:forms [(do exprs*)]
    \\        :doc "Evaluates the expressions in order and returns the value of
    \\  the last. If no expressions are supplied, returns nil."}
    \\    if {:forms [(if test then else?)]
    \\        :doc "Evaluates test. If not the singular values nil or false,
    \\  evaluates and yields then, otherwise, evaluates and yields else. If
    \\  else is not supplied it defaults to nil."}
    \\    quote {:forms [(quote form)]
    \\           :doc "Yields the unevaluated form."}
    \\    recur {:forms [(recur exprs*)]
    \\           :doc "Evaluates the exprs in order, then, in parallel, rebinds
    \\  the bindings of the recursion point to the values of the exprs.
    \\  Execution then jumps back to the recursion point, a loop or fn method."}
    \\    set! {:forms [(set! var-symbol expr)]
    \\          :doc "Sets the thread-local binding of a dynamic var."}
    \\    throw {:forms [(throw expr)]
    \\           :doc "The expr is evaluated and thrown."}
    \\    try {:forms [(try expr* catch-clause* finally-clause?)]
    \\         :doc "catch-clause => (catch classname name expr*)
    \\  finally-clause => (finally expr*)
    \\  Catches and handles exceptions."}
    \\    var {:forms [(var symbol)]
    \\         :doc "The symbol must resolve to a var, and the Var object
    \\  itself (not its value) is returned. The reader macro #'x expands to (var x)."}
    \\    fn {:forms [(fn name? [params*] exprs*) (fn name? ([params*] exprs*) +)]
    \\        :doc "params => positional-params*, or positional-params* & rest-param
    \\  Defines a function (fn)."}
    \\    let {:forms [(let [bindings*] exprs*)]
    \\         :doc "binding => binding-form init-expr
    \\  Evaluates the exprs in a lexical context in which the symbols in
    \\  the binding-forms are bound to their respective init-exprs or parts
    \\  therein."}
    \\    loop {:forms [(loop [bindings*] exprs*)]
    \\          :doc "Evaluates the exprs in a lexical context in which the symbols in
    \\  the binding-forms are bound to their respective init-exprs or parts
    \\  therein. Acts as a recur target."}
    \\    letfn {:forms [(letfn [fnspecs*] exprs*)]
    \\           :doc "fnspec ==> (fname [params*] exprs) or (fname ([params*] exprs)+)
    \\  Takes a vector of function specs and a body, and generates a set of
    \\  bindings of each name to its fn. All of the fns are available in all
    \\  of the definitions of the fns, as well as the body."}})
    \\(defmacro doc
    \\  [name]
    \\  (if-let [special-name ('{& fn catch try finally try} name)]
    \\    `(print-doc (special-doc '~special-name))
    \\    (cond
    \\      (special-doc-map name) `(print-doc (special-doc '~name))
    \\      (keyword? name) `(print-doc {:spec '~name :doc '~(clojure.spec.alpha/describe name)})
    \\      :else `(cond
    \\               (find-ns '~name)
    \\               (print-doc (namespace-doc (find-ns '~name)))
    \\               :else
    \\               (when-let [v# (ns-resolve *ns* '~name)]
    \\                 (print-doc (meta v#)))))))
    \\(defmacro dir
    \\  [nsname]
    \\  `(doseq [v# (dir-fn '~nsname)]
    \\     (println v#)))
    \\(defmacro source
    \\  [n]
    \\  `(println (or (source-fn '~n) (str "Source not found"))))
;

// io.clj removed — now Zig builtins in ns_java_io.zig (Phase B.7)

/// Embedded clojure/pprint.clj source (compiled into binary).
pub const pprint_clj_source = @embedFile("../clj/clojure/pprint.clj");

// stacktrace.clj removed — now Zig builtins in ns_stacktrace.zig (Phase B.4)

// zip.clj removed — now Zig builtins in ns_zip.zig (Phase B.9)

// reducers.clj stubs removed — pool/fjtask/fjinvoke/fjfork/fjjoin/append! now Zig builtins
// in ns_reducers.zig (Phase B.13). Complex code (protocols, macros, reify) remains as evalString.
pub const reducers_macros_source =
    \\(def pool nil)
    \\(defn reduce
    \\  ([f coll] (reduce f (f) coll))
    \\  ([f init coll]
    \\   (if (map? coll)
    \\     (clojure.core.protocols/kv-reduce coll f init)
    \\     (clojure.core.protocols/coll-reduce coll f init))))
    \\(defprotocol CollFold
    \\  (coll-fold [coll n combinef reducef]))
    \\(defn fold
    \\  ([reducef coll] (fold reducef reducef coll))
    \\  ([combinef reducef coll] (fold 512 combinef reducef coll))
    \\  ([n combinef reducef coll]
    \\   (coll-fold coll n combinef reducef)))
    \\(defn monoid [op ctor]
    \\  (fn m
    \\    ([] (ctor))
    \\    ([a b] (op a b))))
    \\(defn reducer [coll xf]
    \\  (reify
    \\    clojure.core.protocols/CollReduce
    \\    (coll-reduce
    \\      ([this f1] (clojure.core.protocols/coll-reduce this f1 (f1)))
    \\      ([_ f1 init] (clojure.core.protocols/coll-reduce coll (xf f1) init)))))
    \\(defn folder [coll xf]
    \\  (reify
    \\    clojure.core.protocols/CollReduce
    \\    (coll-reduce
    \\      ([_ f1] (clojure.core.protocols/coll-reduce coll (xf f1) (f1)))
    \\      ([_ f1 init] (clojure.core.protocols/coll-reduce coll (xf f1) init)))
    \\    CollFold
    \\    (coll-fold [_ n combinef reducef]
    \\      (coll-fold coll n combinef (xf reducef)))))
    \\(defn- do-curried [name doc meta args body]
    \\  (let [cargs (vec (butlast args))]
    \\    `(defn ~name ~doc ~meta
    \\       (~cargs (fn [x#] (~name ~@cargs x#)))
    \\       (~args ~@body))))
    \\(defmacro ^:private defcurried
    \\  [name doc meta args & body]
    \\  (do-curried name doc meta args body))
    \\(defn- do-rfn [f1 k fkv]
    \\  `(fn
    \\     ([] (~f1))
    \\     ~(clojure.walk/postwalk
    \\       #(if (sequential? %)
    \\          ((if (vector? %) vec identity)
    \\           (clojure.core/remove #{k} %))
    \\          %)
    \\       fkv)
    \\     ~fkv))
    \\(defmacro ^:private rfn [[f1 k] fkv]
    \\  (do-rfn f1 k fkv))
    \\(defcurried map "" {} [f coll]
    \\  (folder coll
    \\          (fn [f1]
    \\            (rfn [f1 k]
    \\              ([ret k v]
    \\               (f1 ret (f k v)))))))
    \\(defcurried mapcat "" {} [f coll]
    \\  (folder coll
    \\          (fn [f1]
    \\            (let [f1 (fn
    \\                       ([ret v]
    \\                        (let [x (f1 ret v)] (if (reduced? x) (reduced x) x)))
    \\                       ([ret k v]
    \\                        (let [x (f1 ret k v)] (if (reduced? x) (reduced x) x))))]
    \\              (rfn [f1 k]
    \\                ([ret k v]
    \\                 (reduce f1 ret (f k v))))))))
    \\(defcurried filter "" {} [pred coll]
    \\  (folder coll
    \\          (fn [f1]
    \\            (rfn [f1 k]
    \\              ([ret k v]
    \\               (if (pred k v)
    \\                 (f1 ret k v)
    \\                 ret))))))
    \\(defcurried remove "" {} [pred coll]
    \\  (filter (complement pred) coll))
    \\(defcurried flatten "" {} [coll]
    \\  (folder coll
    \\          (fn [f1]
    \\            (fn
    \\              ([] (f1))
    \\              ([ret v]
    \\               (if (sequential? v)
    \\                 (clojure.core.protocols/coll-reduce (flatten v) f1 ret)
    \\                 (f1 ret v)))))))
    \\(defcurried take-while "" {} [pred coll]
    \\  (reducer coll
    \\           (fn [f1]
    \\             (rfn [f1 k]
    \\               ([ret k v]
    \\                (if (pred k v)
    \\                  (f1 ret k v)
    \\                  (reduced ret)))))))
    \\(defcurried take "" {} [n coll]
    \\  (reducer coll
    \\           (fn [f1]
    \\             (let [cnt (atom n)]
    \\               (rfn [f1 k]
    \\                 ([ret k v]
    \\                  (swap! cnt dec)
    \\                  (if (neg? @cnt)
    \\                    (reduced ret)
    \\                    (f1 ret k v))))))))
    \\(defcurried drop "" {} [n coll]
    \\  (reducer coll
    \\           (fn [f1]
    \\             (let [cnt (atom n)]
    \\               (rfn [f1 k]
    \\                 ([ret k v]
    \\                  (swap! cnt dec)
    \\                  (if (neg? @cnt)
    \\                    (f1 ret k v)
    \\                    ret)))))))
    \\(defrecord Cat [cnt left right])
    \\(extend-type Cat clojure.core.protocols/CollReduce
    \\             (coll-reduce
    \\               ([this f1] (clojure.core.protocols/coll-reduce this f1 (f1)))
    \\               ([this f1 init]
    \\                (clojure.core.protocols/coll-reduce
    \\                 (:right this) f1
    \\                 (clojure.core.protocols/coll-reduce (:left this) f1 init)))))
    \\(extend-type Cat CollFold
    \\             (coll-fold
    \\               [this n combinef reducef]
    \\               (fjinvoke
    \\                (fn []
    \\                  (let [rt (fjfork (fjtask #(coll-fold (:right this) n combinef reducef)))]
    \\                    (combinef
    \\                     (coll-fold (:left this) n combinef reducef)
    \\                     (fjjoin rt)))))))
    \\(defn cat
    \\  ([] [])
    \\  ([ctor]
    \\   (fn
    \\     ([] (ctor))
    \\     ([left right] (cat left right))))
    \\  ([left right]
    \\   (cond
    \\     (zero? (count left)) right
    \\     (zero? (count right)) left
    \\     :else
    \\     (->Cat (+ (count left) (count right)) left right))))
    \\(defn foldcat [coll]
    \\  (fold cat append! coll))
    \\(defn- foldvec [v n combinef reducef]
    \\  (cond
    \\    (empty? v) (combinef)
    \\    (<= (count v) n) (reduce reducef (combinef) v)
    \\    :else
    \\    (let [split (quot (count v) 2)
    \\          v1 (subvec v 0 split)
    \\          v2 (subvec v split (count v))
    \\          fc (fn [child] #(foldvec child n combinef reducef))]
    \\      (fjinvoke
    \\       #(let [f1 (fc v1)
    \\              t2 (fjtask (fc v2))]
    \\          (fjfork t2)
    \\          (combinef (f1) (fjjoin t2)))))))
    \\(extend-type nil CollFold
    \\             (coll-fold
    \\               [coll n combinef reducef]
    \\               (combinef)))
    \\(extend-type Object CollFold
    \\             (coll-fold
    \\               [coll n combinef reducef]
    \\               (reduce reducef (combinef) coll)))
    \\(extend-type Vector CollFold
    \\             (coll-fold
    \\               [v n combinef reducef]
    \\               (foldvec v n combinef reducef)))
;

// test/tap.clj replaced with Zig multiline string (Phase B.14)
pub const test_tap_clj_source =
    \\(ns clojure.test.tap
    \\  (:require [clojure.test :as t]
    \\            [clojure.stacktrace :as stack]
    \\            [clojure.string :as str]))
    \\(defn print-tap-plan
    \\  {:added "1.1"}
    \\  [n]
    \\  (println (clojure.core/str "1.." n)))
    \\(defn print-tap-diagnostic
    \\  {:added "1.1"}
    \\  [data]
    \\  (doseq [line (str/split data #"\n")]
    \\    (println "#" line)))
    \\(defn print-tap-pass
    \\  {:added "1.1"}
    \\  [msg]
    \\  (println "ok" msg))
    \\(defn print-tap-fail
    \\  {:added "1.1"}
    \\  [msg]
    \\  (println "not ok" msg))
    \\(defmulti ^:dynamic tap-report :type)
    \\(defmethod tap-report :default [data]
    \\  (t/with-test-out
    \\    (print-tap-diagnostic (pr-str data))))
    \\(defn print-diagnostics [data]
    \\  (when (seq t/*testing-contexts*)
    \\    (print-tap-diagnostic (t/testing-contexts-str)))
    \\  (when (:message data)
    \\    (print-tap-diagnostic (:message data)))
    \\  (print-tap-diagnostic (clojure.core/str "expected:" (pr-str (:expected data))))
    \\  (if (= :pass (:type data))
    \\    (print-tap-diagnostic (clojure.core/str "  actual:" (pr-str (:actual data))))
    \\    (do
    \\      (print-tap-diagnostic
    \\       (clojure.core/str "  actual:"
    \\                         (with-out-str
    \\                           (if (instance? Exception (:actual data))
    \\                             (stack/print-cause-trace (:actual data) t/*stack-trace-depth*)
    \\                             (prn (:actual data)))))))))
    \\(defmethod tap-report :pass [data]
    \\  (t/with-test-out
    \\    (t/inc-report-counter :pass)
    \\    (print-tap-pass (t/testing-vars-str data))
    \\    (print-diagnostics data)))
    \\(defmethod tap-report :error [data]
    \\  (t/with-test-out
    \\    (t/inc-report-counter :error)
    \\    (print-tap-fail (t/testing-vars-str data))
    \\    (print-diagnostics data)))
    \\(defmethod tap-report :fail [data]
    \\  (t/with-test-out
    \\    (t/inc-report-counter :fail)
    \\    (print-tap-fail (t/testing-vars-str data))
    \\    (print-diagnostics data)))
    \\(defmethod tap-report :summary [data]
    \\  (t/with-test-out
    \\    (print-tap-plan (+ (:pass data) (:fail data) (:error data)))))
    \\(defmacro with-tap-output
    \\  {:added "1.1"}
    \\  [& body]
    \\  `(binding [t/report tap-report]
    \\     ~@body))
;


// instant.clj removed — now Zig builtins in ns_instant.zig (Phase B.8)
// process.clj removed — now Zig builtins in ns_java_process.zig (Phase B.7)

// main.clj functions removed — simple functions now Zig builtins in ns_main.zig (Phase B.12)
// Only macros (with-bindings, with-read-known) and complex fns (repl, ex-triage, ex-str) remain.
pub const main_macros_source =
    \\(ns clojure.main
    \\  (:refer-clojure :exclude [with-bindings])
    \\  (:require [clojure.string]))
    \\(declare main)
    \\(defmacro with-bindings
    \\  [& body]
    \\  `(binding [*ns* *ns*
    \\             *print-meta* *print-meta*
    \\             *print-length* *print-length*
    \\             *print-level* *print-level*
    \\             *data-readers* *data-readers*
    \\             *default-data-reader-fn* *default-data-reader-fn*
    \\             *command-line-args* *command-line-args*]
    \\     ~@body))
    \\(defn- file-name [full-path]
    \\  (when full-path
    \\    (let [idx (max (.lastIndexOf ^String full-path "/")
    \\                   (.lastIndexOf ^String full-path "\\"))]
    \\      (if (neg? idx) full-path (subs full-path (inc idx))))))
    \\(defn- file-path [full-path] full-path)
    \\(defn ex-triage
    \\  {:added "1.10"}
    \\  [datafied-throwable]
    \\  (let [{:keys [via phase] :or {phase :execution}} datafied-throwable
    \\        {:keys [type message data]} (last via)
    \\        {:clojure.error/keys [source] :as top-data} (:data (first via))]
    \\    (assoc
    \\     (cond
    \\       (= phase :read-source)
    \\       (cond-> (merge (-> via second :data) top-data)
    \\         source (assoc :clojure.error/source (file-name source)
    \\                       :clojure.error/path (file-path source))
    \\         message (assoc :clojure.error/cause message))
    \\       (#{:compile-syntax-check :compilation :macro-syntax-check :macroexpansion} phase)
    \\       (cond-> top-data
    \\         source (assoc :clojure.error/source (file-name source)
    \\                       :clojure.error/path (file-path source))
    \\         type (assoc :clojure.error/class type)
    \\         message (assoc :clojure.error/cause message))
    \\       (#{:read-eval-result :print-eval-result} phase)
    \\       (cond-> top-data
    \\         type (assoc :clojure.error/class type)
    \\         message (assoc :clojure.error/cause message))
    \\       :else
    \\       (cond-> {:clojure.error/class type}
    \\         message (assoc :clojure.error/cause message)))
    \\     :clojure.error/phase phase)))
    \\(defn ex-str
    \\  {:added "1.10"}
    \\  [{:clojure.error/keys [phase source path line column symbol class cause spec]
    \\    :as triage-data}]
    \\  (let [loc (str (or path source "REPL") ":" (or line 1) (if column (str ":" column) ""))
    \\        class-name (if class (name class) "")
    \\        simple-class (if class (or (last (clojure.string/split class-name #"\.")) class-name))
    \\        cause-type (if (#{"Exception" "RuntimeException"} simple-class)
    \\                     ""
    \\                     (str " (" simple-class ")"))]
    \\    (cond
    \\      (= phase :read-source)
    \\      (format "Syntax error reading source at (%s).\n%s\n" loc cause)
    \\      (= phase :macro-syntax-check)
    \\      (format "Syntax error macroexpanding %sat (%s).\n%s\n"
    \\              (if symbol (str symbol " ") "") loc (or cause ""))
    \\      (= phase :macroexpansion)
    \\      (format "Unexpected error%s macroexpanding %sat (%s).\n%s\n"
    \\              cause-type (if symbol (str symbol " ") "") loc cause)
    \\      (= phase :compile-syntax-check)
    \\      (format "Syntax error%s compiling %sat (%s).\n%s\n"
    \\              cause-type (if symbol (str symbol " ") "") loc cause)
    \\      (= phase :compilation)
    \\      (format "Unexpected error%s compiling %sat (%s).\n%s\n"
    \\              cause-type (if symbol (str symbol " ") "") loc cause)
    \\      (= phase :read-eval-result)
    \\      (format "Error reading eval result%s at %s (%s).\n%s\n" cause-type symbol loc cause)
    \\      (= phase :print-eval-result)
    \\      (format "Error printing return value%s at %s (%s).\n%s\n" cause-type symbol loc cause)
    \\      (= phase :execution)
    \\      (format "Execution error%s at %s(%s).\n%s\n"
    \\              cause-type (if symbol (str symbol " ") "") loc cause)
    \\      :else
    \\      (format "Error%s (%s).\n%s\n" cause-type loc cause))))
    \\(def ^{:doc "A sequence of lib specs that are applied to `require`
    \\by default when a new command-line REPL is started."} repl-requires
    \\  '[[clojure.repl :refer (doc find-doc)]
    \\    [clojure.pprint :refer (pp pprint)]])
    \\(defmacro with-read-known
    \\  [& body]
    \\  `(binding [*read-eval* (if (= :unknown *read-eval*) true *read-eval*)]
    \\     ~@body))
    \\(defn repl
    \\  [& options]
    \\  (let [{:keys [init need-prompt prompt flush read eval print caught]
    \\         :or {init        #()
    \\              need-prompt #(identity true)
    \\              prompt      repl-prompt
    \\              flush       flush
    \\              read        repl-read
    \\              eval        eval
    \\              print       prn
    \\              caught      repl-caught}}
    \\        (apply hash-map options)
    \\        request-prompt (Object.)
    \\        request-exit (Object.)
    \\        read-eval-print
    \\        (fn []
    \\          (try
    \\            (let [input (with-read-known (read request-prompt request-exit))]
    \\              (or (#{request-prompt request-exit} input)
    \\                  (let [value (eval input)]
    \\                    (try
    \\                      (print value)
    \\                      (catch Exception e
    \\                        (throw (ex-info nil {:clojure.error/phase :print-eval-result} e)))))))
    \\            (catch Exception e
    \\              (caught e))))]
    \\    (with-bindings
    \\      (binding [*repl* true]
    \\        (try
    \\          (init)
    \\          (catch Exception e
    \\            (caught e)))
    \\        (prompt)
    \\        (flush)
    \\        (loop []
    \\          (when-not
    \\           (try (identical? (read-eval-print) request-exit)
    \\                (catch Exception e
    \\                  (caught e)
    \\                  nil))
    \\            (when (need-prompt)
    \\              (prompt)
    \\              (flush))
    \\            (recur)))))))
;

/// Embedded clojure/core/server.clj source (compiled into binary).
// server.clj removed — now Zig builtins in ns_server.zig (Phase B.5)


// xml.clj removed — now Zig builtins in ns_xml.zig (Phase B.11)

// spec/gen/alpha.clj removed — now Zig builtins in lib/clojure_spec_gen_alpha.zig (Phase B.15a)

// core/specs/alpha.clj removed — now Zig builtins in lib/clojure_core_specs_alpha.zig (Phase B.15a)

// spec/alpha.clj replaced with Zig multiline string (Phase B.15b)
// No Zig builtins — spec system stays as evalString due to heavy protocol/reify usage.
pub const spec_alpha_clj_source =
    \\(alias 'c 'clojure.core)
    \\
    \\;; CLJW: (set! *warn-on-reflection* true) — not applicable in CW
    \\
    \\(c/def ^:dynamic *recursion-limit*
    \\  "A soft limit on how many times a branching spec (or/alt/*/opt-keys/multi-spec)
    \\  can be recursed through during generation. After this a
    \\  non-recursive branch will be chosen."
    \\  4)
    \\
    \\(c/def ^:dynamic *fspec-iterations*
    \\  "The number of times an anonymous fn specified by fspec will be (generatively) tested during conform"
    \\  21)
    \\
    \\(c/def ^:dynamic *coll-check-limit*
    \\  "The number of elements validated in a collection spec'ed with 'every'"
    \\  101)
    \\
    \\(c/def ^:dynamic *coll-error-limit*
    \\  "The number of errors reported by explain in a collection spec'ed with 'every'"
    \\  20)
    \\
    \\(defprotocol Spec
    \\  (conform* [spec x])
    \\  (unform* [spec y])
    \\  (explain* [spec path via in x])
    \\  (gen* [spec overrides path rmap])
    \\  (with-gen* [spec gfn])
    \\  (describe* [spec]))
    \\
    \\(defonce ^:private registry-ref (atom {}))
    \\
    \\(defn- deep-resolve [reg k]
    \\  (loop [spec k]
    \\    (if (ident? spec)
    \\      (recur (get reg spec))
    \\      spec)))
    \\
    \\(defn- reg-resolve
    \\  "returns the spec/regex at end of alias chain starting with k, nil if not found, k if k not ident"
    \\  [k]
    \\  (if (ident? k)
    \\    (let [reg @registry-ref
    \\          spec (get reg k)]
    \\      (if-not (ident? spec)
    \\        spec
    \\        (deep-resolve reg spec)))
    \\    k))
    \\
    \\(defn- reg-resolve!
    \\  "returns the spec/regex at end of alias chain starting with k, throws if not found, k if k not ident"
    \\  [k]
    \\  (if (ident? k)
    \\    (c/or (reg-resolve k)
    \\          (throw (ex-info (str "Unable to resolve spec: " k) {:spec k}))) ;; CLJW: ex-info (no Java exceptions)
    \\    k))
    \\
    \\(defn spec?
    \\  "returns x if x is a spec object, else logical false"
    \\  [x]
    \\  ;; CLJW: (satisfies? Spec x) instead of (instance? clojure.spec.alpha.Spec x)
    \\  (when (satisfies? Spec x)
    \\    x))
    \\
    \\(defn regex?
    \\  "returns x if x is a (clojure.spec) regex op, else logical false"
    \\  [x]
    \\  (c/and (::op x) x))
    \\
    \\;; CLJW: Helper to check if an object supports with-meta (replaces instance? IObj)
    \\(defn- meta-obj? [x]
    \\  (c/or (map? x) (vector? x) (list? x) (set? x) (symbol? x) (fn? x) (seq? x)))
    \\
    \\(defn- with-name [spec name]
    \\  (cond
    \\    (ident? spec) spec
    \\    (regex? spec) (assoc spec ::name name)
    \\
    \\   ;; CLJW: meta-obj? instead of (instance? clojure.lang.IObj spec)
    \\    (meta-obj? spec)
    \\    (with-meta spec (assoc (meta spec) ::name name))))
    \\
    \\(defn- spec-name [spec]
    \\  (cond
    \\    (ident? spec) spec
    \\
    \\    (regex? spec) (::name spec)
    \\
    \\   ;; CLJW: meta-obj? instead of (instance? clojure.lang.IObj spec)
    \\    (meta-obj? spec)
    \\    (-> (meta spec) ::name)))
    \\
    \\(declare spec-impl)
    \\(declare regex-spec-impl)
    \\
    \\(defn- maybe-spec
    \\  "spec-or-k must be a spec, regex or resolvable kw/sym, else returns nil."
    \\  [spec-or-k]
    \\  (let [s (c/or (c/and (ident? spec-or-k) (reg-resolve spec-or-k))
    \\                (spec? spec-or-k)
    \\                (regex? spec-or-k)
    \\                nil)]
    \\    (if (regex? s)
    \\      (with-name (regex-spec-impl s nil) (spec-name s))
    \\      s)))
    \\
    \\(defn- the-spec
    \\  "spec-or-k must be a spec, regex or kw/sym, else returns nil. Throws if unresolvable kw/sym"
    \\  [spec-or-k]
    \\  (c/or (maybe-spec spec-or-k)
    \\        (when (ident? spec-or-k)
    \\          (throw (ex-info (str "Unable to resolve spec: " spec-or-k) {:spec spec-or-k}))))) ;; CLJW: ex-info
    \\
    \\(defprotocol Specize
    \\  (specize* [_] [_ form]))
    \\
    \\;; CLJW: fn-sym — In JVM this decompiles class names.
    \\;; CW functions don't carry class names; return nil (uses ::unknown in specize).
    \\;; UPSTREAM-DIFF: fn-sym always returns nil
    \\(defn- fn-sym [f]
    \\  nil)
    \\
    \\(extend-protocol Specize
    \\  Keyword
    \\  (specize* ([k] (specize* (reg-resolve! k)))
    \\    ([k _] (specize* (reg-resolve! k))))
    \\
    \\  Symbol
    \\  (specize* ([s] (specize* (reg-resolve! s)))
    \\    ([s _] (specize* (reg-resolve! s))))
    \\
    \\  PersistentHashSet
    \\  (specize* ([s] (spec-impl s s nil nil))
    \\    ([s form] (spec-impl form s nil nil)))
    \\
    \\  Object
    \\  (specize* ([o] (if (c/and (not (map? o)) (ifn? o))
    \\                   (if-let [s (fn-sym o)]
    \\                     (spec-impl s o nil nil)
    \\                     (spec-impl ::unknown o nil nil))
    \\                   (spec-impl ::unknown o nil nil)))
    \\    ([o form] (spec-impl form o nil nil))))
    \\
    \\(defn- specize
    \\  ([s] (c/or (spec? s) (specize* s)))
    \\  ([s form] (c/or (spec? s) (specize* s form))))
    \\
    \\(defn invalid?
    \\  "tests the validity of a conform return value"
    \\  [ret]
    \\  (identical? ::invalid ret))
    \\
    \\(defn conform
    \\  "Given a spec and a value, returns :clojure.spec.alpha/invalid
    \\  if value does not match spec, else the (possibly destructured) value."
    \\  [spec x]
    \\  (conform* (specize spec) x))
    \\
    \\(defn unform
    \\  "Given a spec and a value created by or compliant with a call to
    \\  'conform' with the same spec, returns a value with all conform
    \\  destructuring undone."
    \\  [spec x]
    \\  (unform* (specize spec) x))
    \\
    \\(defn form
    \\  "returns the spec as data"
    \\  [spec]
    \\  ;;TODO - incorporate gens
    \\  (describe* (specize spec)))
    \\
    \\(defn abbrev [form]
    \\  (cond
    \\    (seq? form)
    \\    (walk/postwalk (fn [form]
    \\                     (cond
    \\                       (c/and (symbol? form) (namespace form))
    \\                       (-> form name symbol)
    \\
    \\                       (c/and (seq? form) (= 'fn (first form)) (= '[%] (second form)))
    \\                       (last form)
    \\
    \\                       :else form))
    \\                   form)
    \\
    \\    (c/and (symbol? form) (namespace form))
    \\    (-> form name symbol)
    \\
    \\    :else form))
    \\
    \\(defn describe
    \\  "returns an abbreviated description of the spec as data"
    \\  [spec]
    \\  (abbrev (form spec)))
    \\
    \\(defn with-gen
    \\  "Takes a spec and a no-arg, generator-returning fn and returns a version of that spec that uses that generator"
    \\  [spec gen-fn]
    \\  (let [spec (reg-resolve spec)]
    \\    (if (regex? spec)
    \\      (assoc spec ::gfn gen-fn)
    \\      (with-gen* (specize spec) gen-fn))))
    \\
    \\(defn explain-data* [spec path via in x]
    \\  (let [probs (explain* (specize spec) path via in x)]
    \\    (when-not (empty? probs)
    \\      {::problems probs
    \\       ::spec spec
    \\       ::value x})))
    \\
    \\(defn explain-data
    \\  "Given a spec and a value x which ought to conform, returns nil if x
    \\  conforms, else a map with at least the key ::problems whose value is
    \\  a collection of problem-maps, where problem-map has at least :path :pred and :val
    \\  keys describing the predicate and the value that failed at that
    \\  path."
    \\  [spec x]
    \\  (explain-data* spec [] (if-let [name (spec-name spec)] [name] []) [] x))
    \\
    \\(defn explain-printer
    \\  "Default printer for explain-data. nil indicates a successful validation."
    \\  [ed]
    \\  (if ed
    \\    (let [problems (->> (::problems ed)
    \\                        (sort-by #(- (count (:in %))))
    \\                        (sort-by #(- (count (:path %)))))]
    \\      ;;(prn {:ed ed})
    \\      (doseq [{:keys [path pred val reason via in] :as prob} problems]
    \\        (pr val)
    \\        (print " - failed: ")
    \\        (if reason (print reason) (pr (abbrev pred)))
    \\        (when-not (empty? in)
    \\          (print (str " in: " (pr-str in))))
    \\        (when-not (empty? path)
    \\          (print (str " at: " (pr-str path))))
    \\        (when-not (empty? via)
    \\          (print (str " spec: " (pr-str (last via)))))
    \\        (doseq [[k v] prob]
    \\          (when-not (#{:path :pred :val :reason :via :in} k)
    \\            (print "\n\t" (pr-str k) " ")
    \\            (pr v)))
    \\        (newline)))
    \\    (println "Success!")))
    \\
    \\(c/def ^:dynamic *explain-out* explain-printer)
    \\
    \\(defn explain-out
    \\  "Prints explanation data (per 'explain-data') to *out* using the printer in *explain-out*,
    \\   by default explain-printer."
    \\  [ed]
    \\  (*explain-out* ed))
    \\
    \\(defn explain
    \\  "Given a spec and a value that fails to conform, prints an explanation to *out*."
    \\  [spec x]
    \\  (explain-out (explain-data spec x)))
    \\
    \\(defn explain-str
    \\  "Given a spec and a value that fails to conform, returns an explanation as a string."
    \\  [spec x]
    \\  (with-out-str (explain spec x)))
    \\
    \\(declare valid?)
    \\
    \\(defn- gensub
    \\  [spec overrides path rmap form]
    \\  (let [spec (specize spec)]
    \\    (if-let [g (c/or (when-let [gfn (c/or (get overrides (c/or (spec-name spec) spec))
    \\                                          (get overrides path))]
    \\                       (gfn))
    \\                     (gen* spec overrides path rmap))]
    \\      (gen/such-that #(valid? spec %) g 100)
    \\      (let [abbr (abbrev form)]
    \\        (throw (ex-info (str "Unable to construct gen at: " path " for: " abbr)
    \\                        {::path path ::form form ::failure :no-gen}))))))
    \\
    \\(defn gen
    \\  "Given a spec, returns the generator for it, or throws if none can
    \\  be constructed. Optionally an overrides map can be provided which
    \\  should map spec names or paths (vectors of keywords) to no-arg
    \\  generator-creating fns. These will be used instead of the generators at those
    \\  names/paths. Note that parent generator (in the spec or overrides
    \\  map) will supersede those of any subtrees. A generator for a regex
    \\  op must always return a sequential collection (i.e. a generator for
    \\  s/? should return either an empty sequence/vector or a
    \\  sequence/vector with one item in it)"
    \\  ([spec] (gen spec nil))
    \\  ([spec overrides] (gensub spec overrides [] {::recursion-limit *recursion-limit*} spec)))
    \\
    \\(defn- ->sym
    \\  "Returns a symbol from a symbol or var"
    \\  [x]
    \\  (if (var? x)
    \\    (let [v x] ;; CLJW: adapted — var→symbol via meta
    \\      (symbol (str (:ns (meta v))) (str (:name (meta v)))))
    \\    x))
    \\
    \\(defn- unfn [expr]
    \\  (if (c/and (seq? expr)
    \\             (symbol? (first expr))
    \\             (= "fn*" (name (first expr))))
    \\    (let [[[s] & form] (rest expr)]
    \\      (conj (walk/postwalk-replace {s '%} form) '[%] 'fn))
    \\    expr))
    \\
    \\(defn- res [form]
    \\  (cond
    \\    (keyword? form) form
    \\    (symbol? form) (c/or (-> form resolve ->sym) form)
    \\    (sequential? form) (walk/postwalk #(if (symbol? %) (res %) %) (unfn form))
    \\    :else form))
    \\
    \\;; CLJW: ^:skip-wiki removed (def analyzer doesn't propagate arbitrary metadata to var)
    \\(defn def-impl
    \\  "Do not call this directly, use 'def'"
    \\  [k form spec]
    \\  (c/assert (c/and (ident? k) (namespace k)) "k must be namespaced keyword or resolvable symbol")
    \\  (if (nil? spec)
    \\    (swap! registry-ref dissoc k)
    \\    (let [spec (if (c/or (spec? spec) (regex? spec) (get @registry-ref spec))
    \\                 spec
    \\                 (spec-impl form spec nil nil))]
    \\      (swap! registry-ref assoc k (with-name spec k))))
    \\  k)
    \\
    \\(defn- ns-qualify
    \\  "Qualify symbol s by resolving it or using the current *ns*."
    \\  [s]
    \\  (if-let [ns-sym (some-> s namespace symbol)]
    \\    (c/or (some-> (get (ns-aliases *ns*) ns-sym) str (symbol (name s)))
    \\          s)
    \\    (symbol (str (ns-name *ns*)) (str s)))) ;; CLJW: (ns-name *ns*) instead of (.name *ns*)
    \\
    \\(defmacro def
    \\  "Given a namespace-qualified keyword or resolvable symbol k, and a
    \\  spec, spec-name, predicate or regex-op makes an entry in the
    \\  registry mapping k to the spec. Use nil to remove an entry in
    \\  the registry for k."
    \\  [k spec-form]
    \\  (let [k (if (symbol? k) (ns-qualify k) k)]
    \\    `(def-impl '~k '~(res spec-form) ~spec-form)))
    \\
    \\(defn registry
    \\  "returns the registry map, prefer 'get-spec' to lookup a spec by name"
    \\  []
    \\  @registry-ref)
    \\
    \\(defn get-spec
    \\  "Returns spec registered for keyword/symbol/var k, or nil."
    \\  [k]
    \\  (get (registry) (if (keyword? k) k (->sym k))))
    \\
    \\(defmacro spec
    \\  "Takes a single predicate form, e.g. can be the name of a predicate,
    \\  like even?, or a fn literal like #(< % 42). Note that it is not
    \\  generally necessary to wrap predicates in spec when using the rest
    \\  of the spec macros, only to attach a unique generator
    \\
    \\  Can also be passed the result of one of the regex ops -
    \\  cat, alt, *, +, ?, in which case it will return a regex-conforming
    \\  spec, useful when nesting an independent regex.
    \\  ---
    \\
    \\  Optionally takes :gen generator-fn, which must be a fn of no args that
    \\  returns a test.check generator.
    \\
    \\  Returns a spec."
    \\  [form & {:keys [gen]}]
    \\  (when form
    \\    `(spec-impl '~(res form) ~form ~gen nil)))
    \\
    \\;;--- dt / valid? / pvalid? (needed by spec-impl) ---
    \\
    \\(defn- dt
    \\  ([pred x form] (dt pred x form nil))
    \\  ([pred x form cpred?]
    \\   (if pred
    \\     (if-let [spec (the-spec pred)]
    \\       (conform spec x)
    \\       (if (ifn? pred)
    \\         (if cpred?
    \\           (pred x)
    \\           (if (pred x) x ::invalid))
    \\         (throw (ex-info (str (pr-str form) " is not a fn, expected predicate fn") {:form form})))) ;; CLJW: ex-info
    \\     x)))
    \\
    \\(defn valid?
    \\  "Helper function that returns true when x is valid for spec."
    \\  ([spec x]
    \\   (let [spec (specize spec)]
    \\     (not (invalid? (conform* spec x)))))
    \\  ([spec x form]
    \\   (let [spec (specize spec form)]
    \\     (not (invalid? (conform* spec x))))))
    \\
    \\(defn- pvalid?
    \\  "internal helper function that returns true when x is valid for spec."
    \\  ([pred x]
    \\   (not (invalid? (dt pred x ::unknown))))
    \\  ([pred x form]
    \\   (not (invalid? (dt pred x form)))))
    \\
    \\;;--- spec-impl (the workhorse reify) ---
    \\
    \\(defn spec-impl
    \\  "Do not call this directly, use 'spec'"
    \\  ([form pred gfn cpred?] (spec-impl form pred gfn cpred? nil))
    \\  ([form pred gfn cpred? unc]
    \\   (cond
    \\     (spec? pred) (cond-> pred gfn (with-gen gfn))
    \\     (regex? pred) (regex-spec-impl pred gfn)
    \\     (ident? pred) (cond-> (the-spec pred) gfn (with-gen gfn))
    \\     :else
    \\     (reify
    \\       Specize
    \\       (specize* [s] s)
    \\       (specize* [s _] s)
    \\
    \\       Spec
    \\       (conform* [_ x] (let [ret (pred x)]
    \\                         (if cpred?
    \\                           ret
    \\                           (if ret x ::invalid))))
    \\       (unform* [_ x] (if cpred?
    \\                        (if unc
    \\                          (unc x)
    \\                          (throw (ex-info "no unform fn for conformer" {}))) ;; CLJW: ex-info
    \\                        x))
    \\       (explain* [_ path via in x]
    \\         (when (invalid? (dt pred x form cpred?))
    \\           [{:path path :pred form :val x :via via :in in}]))
    \\       (gen* [_ _ _ _] (if gfn
    \\                         (gfn)
    \\                         (gen/gen-for-pred pred)))
    \\       (with-gen* [_ gfn] (spec-impl form pred gfn cpred? unc))
    \\       (describe* [_] form)))))
    \\
    \\;;--- Regex engine (Phase 70.3) ---
    \\
    \\(defn- accept [x] {::op ::accept :ret x})
    \\
    \\(defn- accept? [{:keys [::op]}]
    \\  (= ::accept op))
    \\
    \\(defn- pcat* [{[p1 & pr :as ps] :ps, [k1 & kr :as ks] :ks, [f1 & fr :as forms] :forms, ret :ret, rep+ :rep+}]
    \\  (when (every? identity ps)
    \\    (if (accept? p1)
    \\      (let [rp (:ret p1)
    \\            ret (conj ret (if ks {k1 rp} rp))]
    \\        (if pr
    \\          (pcat* {:ps pr :ks kr :forms fr :ret ret})
    \\          (accept ret)))
    \\      {::op ::pcat, :ps ps, :ret ret, :ks ks, :forms forms :rep+ rep+})))
    \\
    \\(defn- pcat [& ps] (pcat* {:ps ps :ret []}))
    \\
    \\(defn cat-impl
    \\  "Do not call this directly, use 'cat'"
    \\  [ks ps forms]
    \\  (pcat* {:ks ks, :ps ps, :forms forms, :ret {}}))
    \\
    \\(defn- rep* [p1 p2 ret splice form]
    \\  (when p1
    \\    ;; CLJW: random-uuid instead of java.util.UUID/randomUUID
    \\    (let [r {::op ::rep, :p2 p2, :splice splice, :forms form :id (random-uuid)}]
    \\      (if (accept? p1)
    \\        (assoc r :p1 p2 :ret (conj ret (:ret p1)))
    \\        (assoc r :p1 p1, :ret ret)))))
    \\
    \\(defn rep-impl
    \\  "Do not call this directly, use '*'"
    \\  [form p] (rep* p p [] false form))
    \\
    \\(defn rep+impl
    \\  "Do not call this directly, use '+'"
    \\  [form p]
    \\  (pcat* {:ps [p (rep* p p [] true form)] :forms `[~form (* ~form)] :ret [] :rep+ form}))
    \\
    \\(defn- filter-alt [ps ks forms f]
    \\  (if (c/or ks forms)
    \\    (let [pks (->> (map vector ps
    \\                        (c/or (seq ks) (repeat nil))
    \\                        (c/or (seq forms) (repeat nil)))
    \\                   (filter #(-> % first f)))]
    \\      [(seq (map first pks)) (when ks (seq (map second pks))) (when forms (seq (map #(nth % 2) pks)))])
    \\    [(seq (filter f ps)) ks forms]))
    \\
    \\(defn- alt* [ps ks forms]
    \\  (let [[[p1 & pr :as ps] [k1 :as ks] forms] (filter-alt ps ks forms identity)]
    \\    (when ps
    \\      (let [ret {::op ::alt, :ps ps, :ks ks :forms forms}]
    \\        (if (nil? pr)
    \\          (if k1
    \\            (if (accept? p1)
    \\              (accept (tagged-ret k1 (:ret p1)))
    \\              ret)
    \\            p1)
    \\          ret)))))
    \\
    \\(defn- alts [& ps] (alt* ps nil nil))
    \\(defn- alt2 [p1 p2] (if (c/and p1 p2) (alts p1 p2) (c/or p1 p2)))
    \\
    \\(defn alt-impl
    \\  "Do not call this directly, use 'alt'"
    \\  [ks ps forms] (assoc (alt* ps ks forms) :id (random-uuid)))
    \\
    \\(defn maybe-impl
    \\  "Do not call this directly, use '?'"
    \\  [p form] (assoc (alt* [p (accept ::nil)] nil [form ::nil]) :maybe form))
    \\
    \\(defn amp-impl
    \\  "Do not call this directly, use '&'"
    \\  [re re-form preds pred-forms]
    \\  {::op ::amp :p1 re :amp re-form :ps preds :forms pred-forms})
    \\
    \\(defn- noret? [p1 pret]
    \\  (c/or (= pret ::nil)
    \\        (c/and (#{::rep ::pcat} (::op (reg-resolve! p1)))
    \\               (empty? pret))
    \\        nil))
    \\
    \\(defn- accept-nil? [p]
    \\  (let [{:keys [::op ps p1 p2 forms] :as p} (reg-resolve! p)]
    \\    (cond
    \\      (= op ::accept) true
    \\      (nil? op) nil
    \\      (= op ::amp) (c/and (accept-nil? p1)
    \\                          (let [ret (-> (preturn p1) (and-preds ps (next forms)))]
    \\                            (not (invalid? ret))))
    \\      (= op ::rep) (c/or (identical? p1 p2) (accept-nil? p1))
    \\      (= op ::pcat) (every? accept-nil? ps)
    \\      (= op ::alt) (c/some accept-nil? ps))))
    \\
    \\(defn- add-ret [p r k]
    \\  (let [{:keys [::op ps splice] :as p} (reg-resolve! p)
    \\        prop #(let [ret (preturn p)]
    \\                (if (empty? ret) r ((if splice into conj) r (if k {k ret} ret))))]
    \\    (cond
    \\      (nil? op) r
    \\      (#{::alt ::accept ::amp} op)
    \\      (let [ret (preturn p)]
    \\        (if (= ret ::nil) r (conj r (if k {k ret} ret))))
    \\      (#{::rep ::pcat} op) (prop))))
    \\
    \\(defn- preturn [p]
    \\  (let [{[p0 & pr :as ps] :ps, [k :as ks] :ks, :keys [::op p1 ret forms] :as p} (reg-resolve! p)]
    \\    (cond
    \\      (= op ::accept) ret
    \\      (nil? op) nil
    \\      (= op ::amp) (let [pret (preturn p1)]
    \\                     (if (noret? p1 pret)
    \\                       ::nil
    \\                       (and-preds pret ps forms)))
    \\      (= op ::rep) (add-ret p1 ret k)
    \\      (= op ::pcat) (add-ret p0 ret k)
    \\      (= op ::alt) (let [[[p0] [k0]] (filter-alt ps ks forms accept-nil?)
    \\                         r (if (nil? p0) ::nil (preturn p0))]
    \\                     (if k0 (tagged-ret k0 r) r)))))
    \\
    \\(defn- deriv
    \\  [p x]
    \\  (let [{[p0 & pr :as ps] :ps, [k0 & kr :as ks] :ks, :keys [::op p1 p2 ret splice forms amp] :as p} (reg-resolve! p)]
    \\    (when p
    \\      (cond
    \\        (= op ::accept) nil
    \\        (nil? op) (let [ret (dt p x p)]
    \\                    (when-not (invalid? ret) (accept ret)))
    \\        (= op ::amp) (when-let [p1 (deriv p1 x)]
    \\                       (if (= ::accept (::op p1))
    \\                         (let [ret (-> (preturn p1) (and-preds ps (next forms)))]
    \\                           (when-not (invalid? ret)
    \\                             (accept ret)))
    \\                         (amp-impl p1 amp ps forms)))
    \\        (= op ::pcat) (alt2 (pcat* {:ps (cons (deriv p0 x) pr), :ks ks, :forms forms, :ret ret})
    \\                            (when (accept-nil? p0) (deriv (pcat* {:ps pr, :ks kr, :forms (next forms), :ret (add-ret p0 ret k0)}) x)))
    \\        (= op ::alt) (alt* (map #(deriv % x) ps) ks forms)
    \\        (= op ::rep) (alt2 (rep* (deriv p1 x) p2 ret splice forms)
    \\                           (when (accept-nil? p1) (deriv (rep* p2 p2 (add-ret p1 ret nil) splice forms) x)))))))
    \\
    \\(defn- op-describe [p]
    \\  (let [{:keys [::op ps ks forms splice p1 rep+ maybe amp] :as p} (reg-resolve! p)]
    \\    (when p
    \\      (cond
    \\        (= op ::accept) nil
    \\        (nil? op) p
    \\        (= op ::amp) (list* 'clojure.spec.alpha/& amp forms)
    \\        (= op ::pcat) (if rep+
    \\                        (list `+ rep+)
    \\                        (cons `cat (mapcat vector (c/or (seq ks) (repeat :_)) forms)))
    \\        (= op ::alt) (if maybe
    \\                       (list `? maybe)
    \\                       (cons `alt (mapcat vector ks forms)))
    \\        (= op ::rep) (list (if splice `+ `*) forms)))))
    \\
    \\(defn- op-explain [form p path via in input]
    \\  (let [[x :as input] input
    \\        {:keys [::op ps ks forms splice p1 p2] :as p} (reg-resolve! p)
    \\        via (if-let [name (spec-name p)] (conj via name) via)
    \\        insufficient (fn [path form]
    \\                       [{:path path
    \\                         :reason "Insufficient input"
    \\                         :pred form
    \\                         :val ()
    \\                         :via via
    \\                         :in in}])]
    \\    (when p
    \\      (cond
    \\        (= op ::accept) nil
    \\        (nil? op) (if (empty? input)
    \\                    (insufficient path form)
    \\                    (explain-1 form p path via in x))
    \\        (= op ::amp) (if (empty? input)
    \\                       (if (accept-nil? p1)
    \\                         (explain-pred-list forms ps path via in (preturn p1))
    \\                         (insufficient path (:amp p)))
    \\                       (if-let [p1 (deriv p1 x)]
    \\                         (explain-pred-list forms ps path via in (preturn p1))
    \\                         (op-explain (:amp p) p1 path via in input)))
    \\        (= op ::pcat) (let [pkfs (map vector
    \\                                      ps
    \\                                      (c/or (seq ks) (repeat nil))
    \\                                      (c/or (seq forms) (repeat nil)))
    \\                            [pred k form] (if (= 1 (count pkfs))
    \\                                            (first pkfs)
    \\                                            (first (remove (fn [[p]] (accept-nil? p)) pkfs)))
    \\                            path (if k (conj path k) path)
    \\                            form (c/or form (op-describe pred))]
    \\                        (if (c/and (empty? input) (not pred))
    \\                          (insufficient path form)
    \\                          (op-explain form pred path via in input)))
    \\        (= op ::alt) (if (empty? input)
    \\                       (insufficient path (op-describe p))
    \\                       (apply concat
    \\                              (map (fn [k form pred]
    \\                                     (op-explain (c/or form (op-describe pred))
    \\                                                 pred
    \\                                                 (if k (conj path k) path)
    \\                                                 via
    \\                                                 in
    \\                                                 input))
    \\                                   (c/or (seq ks) (repeat nil))
    \\                                   (c/or (seq forms) (repeat nil))
    \\                                   ps)))
    \\        (= op ::rep) (op-explain (if (identical? p1 p2)
    \\                                   forms
    \\                                   (op-describe p1))
    \\                                 p1 path via in input)))))
    \\
    \\(defn- op-unform [p x]
    \\  (let [{[p0 & pr :as ps] :ps, [k :as ks] :ks, :keys [::op p1 ret forms rep+ maybe] :as p} (reg-resolve! p)
    \\        kps (zipmap ks ps)]
    \\    (cond
    \\      (= op ::accept) [ret]
    \\      (nil? op) [(unform p x)]
    \\      (= op ::amp) (let [px (reduce #(unform %2 %1) x (reverse ps))]
    \\                     (op-unform p1 px))
    \\      (= op ::rep) (mapcat #(op-unform p1 %) x)
    \\      (= op ::pcat) (if rep+
    \\                      (mapcat #(op-unform p0 %) x)
    \\                      (mapcat (fn [k]
    \\                                (when (contains? x k)
    \\                                  (op-unform (kps k) (get x k))))
    \\                              ks))
    \\      (= op ::alt) (if maybe
    \\                     [(unform p0 x)]
    \\                     (let [[k v] x]
    \\                       (op-unform (kps k) v))))))
    \\
    \\(defn- re-conform [p [x & xs :as data]]
    \\  (if (empty? data)
    \\    (if (accept-nil? p)
    \\      (let [ret (preturn p)]
    \\        (if (= ret ::nil)
    \\          nil
    \\          ret))
    \\      ::invalid)
    \\    (if-let [dp (deriv p x)]
    \\      (recur dp xs)
    \\      ::invalid)))
    \\
    \\(defn- re-explain [path via in re input]
    \\  (loop [p re [x & xs :as data] input i 0]
    \\    (if (empty? data)
    \\      (if (accept-nil? p)
    \\        nil
    \\        (op-explain (op-describe p) p path via in nil))
    \\      (if-let [dp (deriv p x)]
    \\        (recur dp xs (inc i))
    \\        (if (accept? p)
    \\          (if (= (::op p) ::pcat)
    \\            (op-explain (op-describe p) p path via (conj in i) (seq data))
    \\            [{:path path
    \\              :reason "Extra input"
    \\              :pred (op-describe re)
    \\              :val data
    \\              :via via
    \\              :in (conj in i)}])
    \\          (c/or (op-explain (op-describe p) p path via (conj in i) (seq data))
    \\                [{:path path
    \\                  :reason "Extra input"
    \\                  :pred (op-describe p)
    \\                  :val data
    \\                  :via via
    \\                  :in (conj in i)}]))))))
    \\
    \\(defn regex-spec-impl
    \\  "Do not call this directly, use the regex ops"
    \\  [re gfn]
    \\  (reify
    \\    Specize
    \\    (specize* [s] s)
    \\    (specize* [s _] s)
    \\
    \\    Spec
    \\    (conform* [_ x]
    \\      (if (c/or (nil? x) (sequential? x))
    \\        (re-conform re (seq x))
    \\        ::invalid))
    \\    (unform* [_ x] (op-unform re x))
    \\    (explain* [_ path via in x]
    \\      (if (c/or (nil? x) (sequential? x))
    \\        (re-explain path via in re (seq x))
    \\        [{:path path :pred '(or nil? sequential?) :val x :via via :in in}]))
    \\    (gen* [_ _ _ _]
    \\      (if gfn (gfn) nil))
    \\    (with-gen* [_ gfn] (regex-spec-impl re gfn))
    \\    (describe* [_] (op-describe re))))
    \\
    \\;;--- conformer (used in practice, small) ---
    \\
    \\(defmacro conformer
    \\  "Takes a predicate function with the semantics of conform i.e. it should return either a
    \\  (possibly converted) value or :clojure.spec.alpha/invalid, and returns a
    \\  spec that uses it as a predicate/conformer. Optionally takes a
    \\  second fn that does unform of result of first"
    \\  ([f] `(spec-impl '(conformer ~(res f)) ~f nil true))
    \\  ([f unf] `(spec-impl '(conformer ~(res f) ~(res unf)) ~f nil true ~unf)))
    \\
    \\;;--- nonconforming ---
    \\
    \\(defn nonconforming
    \\  "takes a spec and returns a spec that has the same properties except
    \\  'conform' returns the original (not the conformed) value. Note, will specize regex ops."
    \\  [spec]
    \\  (let [spec (delay (specize spec))]
    \\    (reify
    \\      Specize
    \\      (specize* [s] s)
    \\      (specize* [s _] s)
    \\
    \\      Spec
    \\      (conform* [_ x] (let [ret (conform* @spec x)]
    \\                        (if (invalid? ret)
    \\                          ::invalid
    \\                          x)))
    \\      (unform* [_ x] x)
    \\      (explain* [_ path via in x] (explain* @spec path via in x))
    \\      (gen* [_ overrides path rmap] (gen* @spec overrides path rmap))
    \\      (with-gen* [_ gfn] (nonconforming (with-gen* @spec gfn)))
    \\      (describe* [_] `(nonconforming ~(describe* @spec))))))
    \\
    \\;;--- helpers needed by spec impls ---
    \\
    \\(defn- recur-limit? [rmap id path k]
    \\  (c/and (> (get rmap id) (::recursion-limit rmap))
    \\         (contains? (set path) k)))
    \\
    \\(defn- inck [m k]
    \\  (assoc m k (inc (c/or (get m k) 0))))
    \\
    \\(defn- explain-1 [form pred path via in v]
    \\  (let [pred (maybe-spec pred)]
    \\    (if (spec? pred)
    \\      (explain* pred path (if-let [name (spec-name pred)] (conj via name) via) in v)
    \\      [{:path path :pred form :val v :via via :in in}])))
    \\
    \\;; CLJW: tagged-ret — upstream uses clojure.lang.MapEntry constructor.
    \\;; CW map entries are plain vectors, so use [tag ret].
    \\;; UPSTREAM-DIFF: vector instead of MapEntry
    \\(defn- tagged-ret [tag ret]
    \\  [tag ret])
    \\
    \\;;--- s/or ---
    \\
    \\(defmacro or
    \\  "Takes key+pred pairs, e.g.
    \\
    \\  (s/or :even even? :small #(< % 42))
    \\
    \\  Returns a destructuring spec that returns a map entry containing the
    \\  key of the first matching pred and the corresponding value. Thus the
    \\  'key' and 'val' functions can be used to refer generically to the
    \\  components of the tagged return."
    \\  [& key-pred-forms]
    \\  (let [pairs (partition 2 key-pred-forms)
    \\        keys (mapv first pairs)
    \\        pred-forms (mapv second pairs)
    \\        pf (mapv res pred-forms)]
    \\    (c/assert (c/and (even? (count key-pred-forms)) (every? keyword? keys)) "spec/or expects k1 p1 k2 p2..., where ks are keywords")
    \\    `(or-spec-impl ~keys '~pf ~pred-forms nil)))
    \\
    \\(defn or-spec-impl
    \\  "Do not call this directly, use 'or'"
    \\  [keys forms preds gfn]
    \\  (let [id (random-uuid) ;; CLJW: random-uuid instead of java.util.UUID/randomUUID
    \\        kps (zipmap keys preds)
    \\        specs (delay (mapv specize preds forms))
    \\        cform (case (count preds)
    \\                2 (fn [x]
    \\                    (let [specs @specs
    \\                          ret (conform* (specs 0) x)]
    \\                      (if (invalid? ret)
    \\                        (let [ret (conform* (specs 1) x)]
    \\                          (if (invalid? ret)
    \\                            ::invalid
    \\                            (tagged-ret (keys 1) ret)))
    \\                        (tagged-ret (keys 0) ret))))
    \\                3 (fn [x]
    \\                    (let [specs @specs
    \\                          ret (conform* (specs 0) x)]
    \\                      (if (invalid? ret)
    \\                        (let [ret (conform* (specs 1) x)]
    \\                          (if (invalid? ret)
    \\                            (let [ret (conform* (specs 2) x)]
    \\                              (if (invalid? ret)
    \\                                ::invalid
    \\                                (tagged-ret (keys 2) ret)))
    \\                            (tagged-ret (keys 1) ret)))
    \\                        (tagged-ret (keys 0) ret))))
    \\                (fn [x]
    \\                  (let [specs @specs]
    \\                    (loop [i 0]
    \\                      (if (< i (count specs))
    \\                        (let [spec (specs i)]
    \\                          (let [ret (conform* spec x)]
    \\                            (if (invalid? ret)
    \\                              (recur (inc i))
    \\                              (tagged-ret (keys i) ret))))
    \\                        ::invalid)))))]
    \\    (reify
    \\      Specize
    \\      (specize* [s] s)
    \\      (specize* [s _] s)
    \\
    \\      Spec
    \\      (conform* [_ x] (cform x))
    \\      (unform* [_ [k x]] (unform (kps k) x))
    \\      (explain* [this path via in x]
    \\        (when-not (pvalid? this x)
    \\          (apply concat
    \\                 (map (fn [k form pred]
    \\                        (when-not (pvalid? pred x)
    \\                          (explain-1 form pred (conj path k) via in x)))
    \\                      keys forms preds))))
    \\      (gen* [_ overrides path rmap]
    \\        (if gfn
    \\          (gfn)
    \\          (let [gen (fn [k p f]
    \\                      (let [rmap (inck rmap id)]
    \\                        (when-not (recur-limit? rmap id path k)
    \\                          (gen/delay
    \\                            (gensub p overrides (conj path k) rmap f)))))
    \\                gs (remove nil? (map gen keys preds forms))]
    \\            (when-not (empty? gs)
    \\              (gen/one-of gs)))))
    \\      (with-gen* [_ gfn] (or-spec-impl keys forms preds gfn))
    \\      (describe* [_] `(or ~@(mapcat vector keys forms))))))
    \\
    \\;;--- s/and ---
    \\
    \\(defn- and-preds [x preds forms]
    \\  (loop [ret x
    \\         [pred & preds] preds
    \\         [form & forms] forms]
    \\    (if pred
    \\      (let [nret (dt pred ret form)]
    \\        (if (invalid? nret)
    \\          ::invalid
    \\          (recur nret preds forms)))
    \\      ret)))
    \\
    \\(defn- explain-pred-list
    \\  [forms preds path via in x]
    \\  (loop [ret x
    \\         [form & forms] forms
    \\         [pred & preds] preds]
    \\    (when pred
    \\      (let [nret (dt pred ret form)]
    \\        (if (invalid? nret)
    \\          (explain-1 form pred path via in ret)
    \\          (recur nret forms preds))))))
    \\
    \\(defmacro and
    \\  "Takes predicate/spec-forms, e.g.
    \\
    \\  (s/and even? #(< % 42))
    \\
    \\  Returns a spec that returns the conformed value. Successive
    \\  conformed values propagate through rest of predicates."
    \\  [& pred-forms]
    \\  `(and-spec-impl '~(mapv res pred-forms) ~(vec pred-forms) nil))
    \\
    \\(defn and-spec-impl
    \\  "Do not call this directly, use 'and'"
    \\  [forms preds gfn]
    \\  (let [specs (delay (mapv specize preds forms))
    \\        cform
    \\        (case (count preds)
    \\          2 (fn [x]
    \\              (let [specs @specs
    \\                    ret (conform* (specs 0) x)]
    \\                (if (invalid? ret)
    \\                  ::invalid
    \\                  (conform* (specs 1) ret))))
    \\          3 (fn [x]
    \\              (let [specs @specs
    \\                    ret (conform* (specs 0) x)]
    \\                (if (invalid? ret)
    \\                  ::invalid
    \\                  (let [ret (conform* (specs 1) ret)]
    \\                    (if (invalid? ret)
    \\                      ::invalid
    \\                      (conform* (specs 2) ret))))))
    \\          (fn [x]
    \\            (let [specs @specs]
    \\              (loop [ret x i 0]
    \\                (if (< i (count specs))
    \\                  (let [nret (conform* (specs i) ret)]
    \\                    (if (invalid? nret)
    \\                      ::invalid
    \\                      (recur nret (inc i))))
    \\                  ret)))))]
    \\    (reify
    \\      Specize
    \\      (specize* [s] s)
    \\      (specize* [s _] s)
    \\
    \\      Spec
    \\      (conform* [_ x] (cform x))
    \\      (unform* [_ x] (reduce #(unform %2 %1) x (reverse preds)))
    \\      (explain* [_ path via in x] (explain-pred-list forms preds path via in x))
    \\      (gen* [_ overrides path rmap] (if gfn (gfn) (gensub (first preds) overrides path rmap (first forms))))
    \\      (with-gen* [_ gfn] (and-spec-impl forms preds gfn))
    \\      (describe* [_] `(and ~@forms)))))
    \\
    \\;;--- s/merge ---
    \\
    \\(defmacro merge
    \\  "Takes map-validating specs (e.g. 'keys' specs) and
    \\  returns a spec that returns a conformed map satisfying all of the
    \\  specs.  Unlike 'and', merge can generate maps satisfying the
    \\  union of the predicates."
    \\  [& pred-forms]
    \\  `(merge-spec-impl '~(mapv res pred-forms) ~(vec pred-forms) nil))
    \\
    \\(defn merge-spec-impl
    \\  "Do not call this directly, use 'merge'"
    \\  [forms preds gfn]
    \\  (reify
    \\    Specize
    \\    (specize* [s] s)
    \\    (specize* [s _] s)
    \\
    \\    Spec
    \\    (conform* [_ x] (let [ms (map #(dt %1 x %2) preds forms)]
    \\                      (if (some invalid? ms)
    \\                        ::invalid
    \\                        (apply c/merge ms))))
    \\    (unform* [_ x] (apply c/merge (map #(unform % x) (reverse preds))))
    \\    (explain* [_ path via in x]
    \\      (apply concat
    \\             (map #(explain-1 %1 %2 path via in x)
    \\                  forms preds)))
    \\    (gen* [_ overrides path rmap]
    \\      (if gfn
    \\        (gfn)
    \\        (gen/fmap
    \\         #(apply c/merge %)
    \\         (apply gen/tuple (map #(gensub %1 overrides path rmap %2)
    \\                               preds forms)))))
    \\    (with-gen* [_ gfn] (merge-spec-impl forms preds gfn))
    \\    (describe* [_] `(merge ~@forms))))
    \\
    \\;;--- s/keys ---
    \\
    \\(declare or-k-gen and-k-gen)
    \\
    \\(defn- k-gen
    \\  "returns a generator for form f, which can be a keyword or a list
    \\  starting with 'or or 'and."
    \\  [f]
    \\  (cond
    \\    (keyword? f) (gen/return f)
    \\    (= 'or  (first f)) (or-k-gen 1 (rest f))
    \\    (= 'and (first f)) (and-k-gen (rest f))))
    \\
    \\(defn- or-k-gen
    \\  "returns a tuple generator made up of generators for a random subset
    \\  of min-count (default 0) to all elements in s."
    \\  ([s] (or-k-gen 0 s))
    \\  ([min-count s]
    \\   (gen/bind (gen/tuple
    \\              (gen/choose min-count (count s))
    \\              (gen/shuffle (mapv k-gen s)))
    \\             (fn [[n gens]]
    \\               (apply gen/tuple (take n gens))))))
    \\
    \\(defn- and-k-gen
    \\  "returns a tuple generator made up of generators for every element
    \\  in s."
    \\  [s]
    \\  (apply gen/tuple (mapv k-gen s)))
    \\
    \\(defmacro keys
    \\  "Creates and returns a map validating spec. :req and :opt are both
    \\  vectors of namespaced-qualified keywords. The validator will ensure
    \\  the :req keys are present. The :opt keys serve as documentation and
    \\  may be used by the generator.
    \\
    \\  The :req key vector supports 'and' and 'or' for key groups:
    \\
    \\  (s/keys :req [::x ::y (or ::secret (and ::user ::pwd))] :opt [::z])
    \\
    \\  There are also -un versions of :req and :opt. These allow
    \\  you to connect unqualified keys to specs.  In each case, fully
    \\  qualified keywords are passed, which name the specs, but unqualified
    \\  keys (with the same name component) are expected and checked at
    \\  conform-time, and generated during gen:
    \\
    \\  (s/keys :req-un [:my.ns/x :my.ns/y])
    \\
    \\  The above says keys :x and :y are required, and will be validated
    \\  and generated by specs (if they exist) named :my.ns/x :my.ns/y
    \\  respectively.
    \\
    \\  In addition, the values of *all* namespace-qualified keys will be validated
    \\  (and possibly destructured) by any registered specs. Note: there is
    \\  no support for inline value specification, by design.
    \\
    \\  Optionally takes :gen generator-fn, which must be a fn of no args that
    \\  returns a test.check generator."
    \\  [& {:keys [req req-un opt opt-un gen]}]
    \\  (let [unk #(-> % name keyword)
    \\        req-keys (filterv keyword? (flatten req))
    \\        req-un-specs (filterv keyword? (flatten req-un))
    \\        _ (c/assert (every? #(c/and (keyword? %) (namespace %)) (concat req-keys req-un-specs opt opt-un))
    \\                    "all keys must be namespace-qualified keywords")
    \\        req-specs (into req-keys req-un-specs)
    \\        req-keys (into req-keys (map unk req-un-specs))
    \\        opt-keys (into (vec opt) (map unk opt-un))
    \\        opt-specs (into (vec opt) opt-un)
    \\        gx (gensym)
    \\        parse-req (fn [rk f]
    \\                    (map (fn [x]
    \\                           (if (keyword? x)
    \\                             `(contains? ~gx ~(f x))
    \\                             (walk/postwalk
    \\                              (fn [y] (if (keyword? y) `(contains? ~gx ~(f y)) y))
    \\                              x)))
    \\                         rk))
    \\        pred-exprs [`(map? ~gx)]
    \\        pred-exprs (into pred-exprs (parse-req req identity))
    \\        pred-exprs (into pred-exprs (parse-req req-un unk))
    \\        keys-pred `(fn* [~gx] (c/and ~@pred-exprs))
    \\        pred-exprs (mapv (fn [e] `(fn* [~gx] ~e)) pred-exprs)
    \\        pred-forms (walk/postwalk res pred-exprs)]
    \\    `(map-spec-impl {:req '~req :opt '~opt :req-un '~req-un :opt-un '~opt-un
    \\                     :req-keys '~req-keys :req-specs '~req-specs
    \\                     :opt-keys '~opt-keys :opt-specs '~opt-specs
    \\                     :pred-forms '~pred-forms
    \\                     :pred-exprs ~pred-exprs
    \\                     :keys-pred ~keys-pred
    \\                     :gfn ~gen})))
    \\
    \\(defn map-spec-impl
    \\  "Do not call this directly, use 'keys'"
    \\  [{:keys [req-un opt-un keys-pred pred-exprs opt-keys req-specs req req-keys opt-specs pred-forms opt gfn]
    \\    :as argm}]
    \\  (let [k->s (zipmap (concat req-keys opt-keys) (concat req-specs opt-specs))
    \\        keys->specnames #(c/or (k->s %) %)
    \\        id (random-uuid)] ;; CLJW: random-uuid
    \\    (reify
    \\      Specize
    \\      (specize* [s] s)
    \\      (specize* [s _] s)
    \\
    \\      Spec
    \\      (conform* [_ m]
    \\        (if (keys-pred m)
    \\          (let [reg (registry)]
    \\            (loop [ret m, [[k v] & ks :as keys] m]
    \\              (if keys
    \\                (let [sname (keys->specnames k)]
    \\                  (if-let [s (get reg sname)]
    \\                    (let [cv (conform s v)]
    \\                      (if (invalid? cv)
    \\                        ::invalid
    \\                        (recur (if (identical? cv v) ret (assoc ret k cv))
    \\                               ks)))
    \\                    (recur ret ks)))
    \\                ret)))
    \\          ::invalid))
    \\      (unform* [_ m]
    \\        (let [reg (registry)]
    \\          (loop [ret m, [k & ks :as keys] (c/keys m)]
    \\            (if keys
    \\              (if (contains? reg (keys->specnames k))
    \\                (let [cv (get m k)
    \\                      v (unform (keys->specnames k) cv)]
    \\                  (recur (if (identical? cv v) ret (assoc ret k v))
    \\                         ks))
    \\                (recur ret ks))
    \\              ret))))
    \\      (explain* [_ path via in x]
    \\        (if-not (map? x)
    \\          [{:path path :pred `map? :val x :via via :in in}]
    \\          (let [reg (registry)]
    \\            (apply concat
    \\                   (when-let [probs (->> (map (fn [pred form] (when-not (pred x) form))
    \\                                              pred-exprs pred-forms)
    \\                                         (keep identity)
    \\                                         seq)]
    \\                     (map
    \\                      #(identity {:path path :pred % :val x :via via :in in})
    \\                      probs))
    \\                   (map (fn [[k v]]
    \\                          (when-not (c/or (not (contains? reg (keys->specnames k)))
    \\                                          (pvalid? (keys->specnames k) v k))
    \\                            (explain-1 (keys->specnames k) (keys->specnames k) (conj path k) via (conj in k) v)))
    \\                        (seq x))))))
    \\      (gen* [_ overrides path rmap]
    \\        (if gfn
    \\          (gfn)
    \\          (let [rmap (inck rmap id)
    \\                rgen (fn [k s] [k (gensub s overrides (conj path k) rmap k)])
    \\                ogen (fn [k s]
    \\                       (when-not (recur-limit? rmap id path k)
    \\                         [k (gen/delay (gensub s overrides (conj path k) rmap k))]))
    \\                reqs (map rgen req-keys req-specs)
    \\                opts (remove nil? (map ogen opt-keys opt-specs))]
    \\            (when (every? identity (concat (map second reqs) (map second opts)))
    \\              (gen/bind
    \\               (gen/tuple
    \\                (and-k-gen req)
    \\                (or-k-gen opt)
    \\                (and-k-gen req-un)
    \\                (or-k-gen opt-un))
    \\               (fn [[req-ks opt-ks req-un-ks opt-un-ks]]
    \\                 (let [qks (flatten (concat req-ks opt-ks))
    \\                       unqks (map (comp keyword name) (flatten (concat req-un-ks opt-un-ks)))]
    \\                   (->> (into reqs opts)
    \\                        (filter #((set (concat qks unqks)) (first %)))
    \\                        (apply concat)
    \\                        (apply gen/hash-map)))))))))
    \\      (with-gen* [_ gfn] (map-spec-impl (assoc argm :gfn gfn)))
    \\      (describe* [_] (cons `keys
    \\                           (cond-> []
    \\                             req (conj :req req)
    \\                             opt (conj :opt opt)
    \\                             req-un (conj :req-un req-un)
    \\                             opt-un (conj :opt-un opt-un)))))))
    \\
    \\;;--- s/tuple ---
    \\
    \\(defmacro tuple
    \\  "takes one or more preds and returns a spec for a tuple, a vector
    \\  where each element conforms to the corresponding pred. Each element
    \\  will be referred to in paths using its ordinal."
    \\  [& preds]
    \\  (c/assert (not (empty? preds)))
    \\  `(tuple-impl '~(mapv res preds) ~(vec preds)))
    \\
    \\(defn tuple-impl
    \\  "Do not call this directly, use 'tuple'"
    \\  ([forms preds] (tuple-impl forms preds nil))
    \\  ([forms preds gfn]
    \\   (let [specs (delay (mapv specize preds forms))
    \\         cnt (count preds)]
    \\     (reify
    \\       Specize
    \\       (specize* [s] s)
    \\       (specize* [s _] s)
    \\
    \\       Spec
    \\       (conform* [_ x]
    \\         (let [specs @specs]
    \\           (if-not (c/and (vector? x)
    \\                          (= (count x) cnt))
    \\             ::invalid
    \\             (loop [ret x, i 0]
    \\               (if (= i cnt)
    \\                 ret
    \\                 (let [v (x i)
    \\                       cv (conform* (specs i) v)]
    \\                   (if (invalid? cv)
    \\                     ::invalid
    \\                     (recur (if (identical? cv v) ret (assoc ret i cv))
    \\                            (inc i)))))))))
    \\       (unform* [_ x]
    \\         (c/assert (c/and (vector? x)
    \\                          (= (count x) (count preds))))
    \\         (loop [ret x, i 0]
    \\           (if (= i (count x))
    \\             ret
    \\             (let [cv (x i)
    \\                   v (unform (preds i) cv)]
    \\               (recur (if (identical? cv v) ret (assoc ret i v))
    \\                      (inc i))))))
    \\       (explain* [_ path via in x]
    \\         (cond
    \\           (not (vector? x))
    \\           [{:path path :pred `vector? :val x :via via :in in}]
    \\
    \\           (not= (count x) (count preds))
    \\           [{:path path :pred `(= (count ~'%) ~(count preds)) :val x :via via :in in}]
    \\
    \\           :else
    \\           (apply concat
    \\                  (map (fn [i form pred]
    \\                         (let [v (x i)]
    \\                           (when-not (pvalid? pred v)
    \\                             (explain-1 form pred (conj path i) via (conj in i) v))))
    \\                       (range (count preds)) forms preds))))
    \\       (gen* [_ overrides path rmap]
    \\         (if gfn
    \\           (gfn)
    \\           (let [gen (fn [i p f]
    \\                       (gensub p overrides (conj path i) rmap f))
    \\                 gs (map gen (range (count preds)) preds forms)]
    \\             (when (every? identity gs)
    \\               (apply gen/tuple gs)))))
    \\       (with-gen* [_ gfn] (tuple-impl forms preds gfn))
    \\       (describe* [_] `(tuple ~@forms))))))
    \\
    \\;;--- s/nilable ---
    \\
    \\(defn nilable-impl
    \\  "Do not call this directly, use 'nilable'"
    \\  [form pred gfn]
    \\  (let [spec (delay (specize pred form))]
    \\    (reify
    \\      Specize
    \\      (specize* [s] s)
    \\      (specize* [s _] s)
    \\
    \\      Spec
    \\      (conform* [_ x] (if (nil? x) nil (conform* @spec x)))
    \\      (unform* [_ x] (if (nil? x) nil (unform* @spec x)))
    \\      (explain* [_ path via in x]
    \\        (when-not (c/or (pvalid? @spec x) (nil? x))
    \\          (conj
    \\           (explain-1 form pred (conj path ::pred) via in x)
    \\           {:path (conj path ::nil) :pred 'nil? :val x :via via :in in})))
    \\      (gen* [_ overrides path rmap]
    \\        (if gfn
    \\          (gfn)
    \\          (gen/frequency
    \\           [[1 (gen/delay (gen/return nil))]
    \\            [9 (gen/delay (gensub pred overrides (conj path ::pred) rmap form))]])))
    \\      (with-gen* [_ gfn] (nilable-impl form pred gfn))
    \\      (describe* [_] `(nilable ~(res form))))))
    \\
    \\(defmacro nilable
    \\  "returns a spec that accepts nil and values satisfying pred"
    \\  [pred]
    \\  (let [pf (res pred)]
    \\    `(nilable-impl '~pf ~pred nil)))
    \\
    \\;;--- s/every, s/coll-of, s/every-kv, s/map-of ---
    \\
    \\(defn- res-kind
    \\  [opts]
    \\  (let [{kind :kind :as mopts} opts]
    \\    (->>
    \\     (if kind
    \\       (assoc mopts :kind `~(res kind))
    \\       mopts)
    \\     (mapcat identity))))
    \\
    \\(defn- coll-prob [x kfn kform distinct count min-count max-count
    \\                  path via in]
    \\  (let [pred (c/or kfn coll?)
    \\        kform (c/or kform `coll?)]
    \\    (cond
    \\      (not (pvalid? pred x))
    \\      (explain-1 kform pred path via in x)
    \\
    \\      (c/and count (not= count (bounded-count count x)))
    \\      [{:path path :pred `(= ~count (c/count ~'%)) :val x :via via :in in}]
    \\
    \\      ;; CLJW: Long/MAX_VALUE instead of Integer/MAX_VALUE
    \\      (c/and (c/or min-count max-count)
    \\             (not (<= (c/or min-count 0)
    \\                      (bounded-count (if max-count (inc max-count) min-count) x)
    \\                      (c/or max-count Long/MAX_VALUE))))
    \\      [{:path path :pred `(<= ~(c/or min-count 0) (c/count ~'%) ~(c/or max-count 'Long/MAX_VALUE)) :val x :via via :in in}]
    \\
    \\      (c/and distinct (not (empty? x)) (not (apply distinct? x)))
    \\      [{:path path :pred 'distinct? :val x :via via :in in}])))
    \\
    \\(def ^:private empty-coll {`vector? [], `set? #{}, `list? (), `map? {}})
    \\
    \\(defn every-impl
    \\  "Do not call this directly, use 'every', 'every-kv', 'coll-of' or 'map-of'"
    \\  ([form pred opts] (every-impl form pred opts nil))
    \\  ([form pred {conform-into :into
    \\               describe-form ::describe
    \\               :keys [kind ::kind-form count max-count min-count distinct gen-max ::kfn ::cpred
    \\                      conform-keys ::conform-all]
    \\               :or {gen-max 20}
    \\               :as opts}
    \\    gfn]
    \\   (let [gen-into (if conform-into (empty conform-into) (get empty-coll kind-form))
    \\         spec (delay (specize pred))
    \\         check? #(valid? @spec %)
    \\         kfn (c/or kfn (fn [i v] i))
    \\         addcv (fn [ret i v cv] (conj ret cv))
    \\         cfns (fn [x]
    \\                (cond
    \\                  (c/and (vector? x) (c/or (not conform-into) (vector? conform-into)))
    \\                  [identity
    \\                   (fn [ret i v cv]
    \\                     (if (identical? v cv)
    \\                       ret
    \\                       (assoc ret i cv)))
    \\                   identity]
    \\
    \\                  (c/and (map? x) (c/or (c/and kind (not conform-into)) (map? conform-into)))
    \\                  [(if conform-keys empty identity)
    \\                   (fn [ret i v cv]
    \\                     (if (c/and (identical? v cv) (not conform-keys))
    \\                       ret
    \\                       (assoc ret (nth (if conform-keys cv v) 0) (nth cv 1))))
    \\                   identity]
    \\
    \\                  (c/or (list? conform-into) (seq? conform-into) (c/and (not conform-into) (c/or (list? x) (seq? x))))
    \\                  [(constantly ()) addcv reverse]
    \\
    \\                  :else [#(empty (c/or conform-into %)) addcv identity]))]
    \\     (reify
    \\       Specize
    \\       (specize* [s] s)
    \\       (specize* [s _] s)
    \\
    \\       Spec
    \\       (conform* [_ x]
    \\         (let [spec @spec]
    \\           (cond
    \\             (not (cpred x)) ::invalid
    \\
    \\             conform-all
    \\             (let [[init add complete] (cfns x)]
    \\               (loop [ret (init x), i 0, [v & vs :as vseq] (seq x)]
    \\                 (if vseq
    \\                   (let [cv (conform* spec v)]
    \\                     (if (invalid? cv)
    \\                       ::invalid
    \\                       (recur (add ret i v cv) (inc i) vs)))
    \\                   (complete ret))))
    \\
    \\             :else
    \\             (if (indexed? x)
    \\               (let [step (max 1 (long (/ (c/count x) *coll-check-limit*)))]
    \\                 (loop [i 0]
    \\                   (if (>= i (c/count x))
    \\                     x
    \\                     (if (valid? spec (nth x i))
    \\                       (recur (c/+ i step))
    \\                       ::invalid))))
    \\               (let [limit *coll-check-limit*]
    \\                 (loop [i 0 [v & vs :as vseq] (seq x)]
    \\                   (cond
    \\                     (c/or (nil? vseq) (= i limit)) x
    \\                     (valid? spec v) (recur (inc i) vs)
    \\                     :else ::invalid)))))))
    \\       (unform* [_ x]
    \\         (if conform-all
    \\           (let [spec @spec
    \\                 [init add complete] (cfns x)]
    \\             (loop [ret (init x), i 0, [v & vs :as vseq] (seq x)]
    \\               (if (>= i (c/count x))
    \\                 (complete ret)
    \\                 (recur (add ret i v (unform* spec v)) (inc i) vs))))
    \\           x))
    \\       (explain* [_ path via in x]
    \\         (c/or (coll-prob x kind kind-form distinct count min-count max-count
    \\                          path via in)
    \\               (apply concat
    \\                      ((if conform-all identity (partial take *coll-error-limit*))
    \\                       (keep identity
    \\                             (map (fn [i v]
    \\                                    (let [k (kfn i v)]
    \\                                      (when-not (check? v)
    \\                                        (let [prob (explain-1 form pred path via (conj in k) v)]
    \\                                          prob))))
    \\                                  (range) x))))))
    \\       (gen* [_ overrides path rmap]
    \\         (if gfn
    \\           (gfn)
    \\           (let [pgen (gensub pred overrides path rmap form)]
    \\             (gen/bind
    \\              (cond
    \\                gen-into (gen/return gen-into)
    \\                kind (gen/fmap #(if (empty? %) % (empty %))
    \\                               (gensub kind overrides path rmap form))
    \\                :else (gen/return []))
    \\              (fn [init]
    \\                (gen/fmap
    \\                 #(if (vector? init) % (into init %))
    \\                 (cond
    \\                   distinct
    \\                   (if count
    \\                     (gen/vector-distinct pgen {:num-elements count :max-tries 100})
    \\                     (gen/vector-distinct pgen {:min-elements (c/or min-count 0)
    \\                                                :max-elements (c/or max-count (max gen-max (c/* 2 (c/or min-count 0))))
    \\                                                :max-tries 100}))
    \\
    \\                   count
    \\                   (gen/vector pgen count)
    \\
    \\                   (c/or min-count max-count)
    \\                   (gen/vector pgen (c/or min-count 0) (c/or max-count (max gen-max (c/* 2 (c/or min-count 0)))))
    \\
    \\                   :else
    \\                   (gen/vector pgen 0 gen-max))))))))
    \\
    \\       (with-gen* [_ gfn] (every-impl form pred opts gfn))
    \\       (describe* [_] (c/or describe-form `(every ~(res form) ~@(mapcat identity opts))))))))
    \\
    \\(defmacro every
    \\  "takes a pred and validates collection elements against that pred.
    \\
    \\  Note that 'every' does not do exhaustive checking, rather it samples
    \\  *coll-check-limit* elements. Nor (as a result) does it do any
    \\  conforming of elements. 'explain' will report at most *coll-error-limit*
    \\  problems.  Thus 'every' should be suitable for potentially large
    \\  collections.
    \\
    \\  Takes several kwargs options that further constrain the collection:
    \\
    \\  :kind - a pred that the collection type must satisfy, e.g. vector?
    \\        (default nil) Note that if :kind is specified and :into is
    \\        not, this pred must generate in order for every to generate.
    \\  :count - specifies coll has exactly this count (default nil)
    \\  :min-count, :max-count - coll has count (<= min-count count max-count) (defaults nil)
    \\  :distinct - all the elements are distinct (default nil)
    \\
    \\  And additional args that control gen
    \\
    \\  :gen-max - the maximum coll size to generate (default 20)
    \\  :into - one of [], (), {}, #{} - the default collection to generate into
    \\      (default: empty coll as generated by :kind pred if supplied, else [])
    \\
    \\  Optionally takes :gen generator-fn, which must be a fn of no args that
    \\  returns a test.check generator
    \\
    \\  See also - coll-of, every-kv"
    \\  [pred & {:keys [into kind count max-count min-count distinct gen-max gen] :as opts}]
    \\  (let [desc (::describe opts)
    \\        nopts (-> opts
    \\                  (dissoc :gen ::describe)
    \\                  (assoc ::kind-form `'~(res (:kind opts))
    \\                         ::describe (c/or desc `'(every ~(res pred) ~@(res-kind opts)))))
    \\        gx (gensym)
    \\        ;; CLJW: Long/MAX_VALUE instead of Integer/MAX_VALUE
    \\        cpreds (cond-> [(list (c/or kind `coll?) gx)]
    \\                 count (conj `(= ~count (bounded-count ~count ~gx)))
    \\
    \\                 (c/or min-count max-count)
    \\                 (conj `(<= (c/or ~min-count 0)
    \\                            (bounded-count (if ~max-count (inc ~max-count) ~min-count) ~gx)
    \\                            (c/or ~max-count Long/MAX_VALUE)))
    \\
    \\                 distinct
    \\                 (conj `(c/or (empty? ~gx) (apply distinct? ~gx))))]
    \\    `(every-impl '~pred ~pred ~(assoc nopts ::cpred `(fn* [~gx] (c/and ~@cpreds))) ~gen)))
    \\
    \\(defmacro every-kv
    \\  "like 'every' but takes separate key and val preds and works on associative collections.
    \\
    \\  Same options as 'every', :into defaults to {}
    \\
    \\  See also - map-of"
    \\  [kpred vpred & opts]
    \\  (let [desc `(every-kv ~(res kpred) ~(res vpred) ~@(res-kind opts))]
    \\    `(every (tuple ~kpred ~vpred) ::kfn (fn [i# v#] (nth v# 0)) :into {} ::describe '~desc ~@opts)))
    \\
    \\(defmacro coll-of
    \\  "Returns a spec for a collection of items satisfying pred. Unlike
    \\  'every', coll-of will exhaustively conform every value.
    \\
    \\  Same options as 'every'. conform will produce a collection
    \\  corresponding to :into if supplied, else will match the input collection,
    \\  avoiding rebuilding when possible.
    \\
    \\  See also - every, map-of"
    \\  [pred & opts]
    \\  (let [desc `(coll-of ~(res pred) ~@(res-kind opts))]
    \\    `(every ~pred ::conform-all true ::describe '~desc ~@opts)))
    \\
    \\(defmacro map-of
    \\  "Returns a spec for a map whose keys satisfy kpred and vals satisfy
    \\  vpred. Unlike 'every-kv', map-of will exhaustively conform every
    \\  value.
    \\
    \\  Same options as 'every', :kind defaults to map?, with the addition of:
    \\
    \\  :conform-keys - conform keys as well as values (default false)
    \\
    \\  See also - every-kv"
    \\  [kpred vpred & opts]
    \\  (let [desc `(map-of ~(res kpred) ~(res vpred) ~@(res-kind opts))]
    \\    `(every-kv ~kpred ~vpred ::conform-all true :kind map? ::describe '~desc ~@opts)))
    \\
    \\;;--- Phase 70.3: Regex macros + advanced specs ---
    \\
    \\(defmacro cat
    \\  "Takes key+pred pairs, e.g.
    \\  (s/cat :e1 e1-pred :e2 e2-pred ...)
    \\  Returns a regex op that matches (all) values in sequence, returning a map
    \\  with the keys."
    \\  [& key-pred-forms]
    \\  (let [pairs (partition 2 key-pred-forms)
    \\        ks (mapv first pairs)
    \\        ps (mapv second pairs)
    \\        pf (mapv res ps)]
    \\    `(cat-impl ~ks ~ps '~pf)))
    \\
    \\(defmacro alt
    \\  "Takes key+pred pairs, e.g.
    \\  (s/alt :even even? :small #(< % 42))
    \\  Returns a regex op that returns a map entry containing the key of the
    \\  first matching pred and the corresponding value."
    \\  [& key-pred-forms]
    \\  (let [pairs (partition 2 key-pred-forms)
    \\        ks (mapv first pairs)
    \\        ps (mapv second pairs)
    \\        pf (mapv res ps)]
    \\    `(alt-impl ~ks ~ps '~pf)))
    \\
    \\(defmacro *
    \\  "Returns a regex op that matches zero or more values matching
    \\  pred. Produces a vector of matches iff there is at least one match"
    \\  [pred-form]
    \\  `(rep-impl '~(res pred-form) ~(res pred-form)))
    \\
    \\(defmacro +
    \\  "Returns a regex op that matches one or more values matching
    \\  pred. Produces a vector of matches"
    \\  [pred-form]
    \\  `(rep+impl '~(res pred-form) ~(res pred-form)))
    \\
    \\(defmacro ?
    \\  "Returns a regex op that matches zero or one value matching
    \\  pred. Produces a single value (not a collection) if matched."
    \\  [pred-form]
    \\  `(maybe-impl ~(res pred-form) '~(res pred-form)))
    \\
    \\(defmacro &
    \\  "Takes a regex op re, and predicates. Returns a regex-op that consumes
    \\  input as per re but subjects the resulting value to the conjunction of
    \\  the predicates, and any conforming they might perform."
    \\  [re & preds]
    \\  (let [pv (vec preds)]
    \\    `(amp-impl ~re '~(res re) ~pv '~(mapv res pv))))
    \\
    \\;;--- fspec ---
    \\
    \\;; CLJW: fspec simplified — conform only checks ifn?, no gen-based testing.
    \\;; Upstream generates args, calls fn, validates ret + :fn spec.
    \\(defn fspec-impl
    \\  "Do not call this directly, use 'fspec'"
    \\  [argspec aform retspec rform fnspec fform gfn]
    \\  (let [specs {:args argspec :ret retspec :fn fnspec}]
    \\    (reify
    \\      Specize
    \\      (specize* [s] s)
    \\      (specize* [s _] s)
    \\
    \\      Spec
    \\      (conform* [_ f]
    \\        (if (ifn? f) f ::invalid))
    \\      (unform* [_ f] f)
    \\      (explain* [_ path via in f]
    \\        (if (ifn? f)
    \\          nil
    \\          [{:path path :pred 'ifn? :val f :via via :in in}]))
    \\      (gen* [_ _ _ _]
    \\        (if gfn (gfn) nil))
    \\      (with-gen* [_ gfn] (fspec-impl argspec aform retspec rform fnspec fform gfn))
    \\      (describe* [_] `(fspec :args ~aform :ret ~rform :fn ~fform)))))
    \\
    \\(defmacro fspec
    \\  "takes :args :ret and (optional) :fn kwargs whose values are preds
    \\  and returns a spec whose conform/explain take a fn and validates it
    \\  using generative testing."
    \\  [& {:keys [args ret fn] :or {ret `any?}}]
    \\  `(fspec-impl (spec ~args) '~(res args) (spec ~ret) '~(res ret) (spec ~fn) '~(res fn) nil))
    \\
    \\(defmacro fdef
    \\  "Takes a symbol naming a function, and one or more of the following:
    \\  :args A regex spec for the function arguments
    \\  :ret A spec for the function's return value
    \\  :fn A spec of the relationship between args and ret"
    \\  [fn-sym & specs]
    \\  `(clojure.spec.alpha/def ~fn-sym (clojure.spec.alpha/fspec ~@specs)))
    \\
    \\;;--- multi-spec ---
    \\
    \\;; CLJW: multi-spec-impl adapted for CW's defmulti implementation.
    \\;; Uses dispatch-fn and get-method instead of Java reflection.
    \\(defn multi-spec-impl
    \\  "Do not call this directly, use 'multi-spec'"
    \\  ([form mmvar retag] (multi-spec-impl form mmvar retag nil))
    \\  ([form mmvar retag gfn]
    \\   (let [id (random-uuid)
    \\         ;; CLJW: access multimethod internals via CW's defmulti
    \\         predx #(let [mm @mmvar
    \\                      dispatch-val ((get mm :dispatch-fn) %)]
    \\                  (when (get-method mm dispatch-val)
    \\                    (mm %)))
    \\         dval #((get @mmvar :dispatch-fn) %)
    \\         tag (if (keyword? retag)
    \\               #(assoc %1 retag %2)
    \\               retag)]
    \\     (reify
    \\       Specize
    \\       (specize* [s] s)
    \\       (specize* [s _] s)
    \\
    \\       Spec
    \\       (conform* [_ x]
    \\         (if-let [pred (predx x)]
    \\           (dt pred x form)
    \\           ::invalid))
    \\       (unform* [_ x]
    \\         (if-let [pred (predx x)]
    \\           (unform pred x)
    \\           (throw (ex-info (str "No method of: " form " for dispatch value: " (dval x)) {}))))
    \\       (explain* [_ path via in x]
    \\         (let [dv (dval x)
    \\               path (conj path dv)]
    \\           (if-let [pred (predx x)]
    \\             (explain-1 form pred path via in x)
    \\             [{:path path :pred form :val x :reason "no method" :via via :in in}])))
    \\       (gen* [_ _ _ _]
    \\         (if gfn (gfn) nil))
    \\       (with-gen* [_ gfn] (multi-spec-impl form mmvar retag gfn))
    \\       (describe* [_] `(multi-spec ~form ~retag))))))
    \\
    \\(defmacro multi-spec
    \\  "Takes the name of a spec'd multimethod and a tag-restoring keyword or fn
    \\  (retag). Returns a spec that when conforming or explaining data will
    \\  dispatch on the value to the multimethod, using the retag to conj/assoc
    \\  the dispatch-val onto the conforming value."
    \\  [mm retag]
    \\  `(multi-spec-impl '~mm (var ~mm) ~retag))
    \\
    \\;;--- assert ---
    \\
    \\;; CLJW: *compile-asserts* — always true (no system properties)
    \\(defonce ^:dynamic *compile-asserts* true)
    \\
    \\;; CLJW: Runtime assert check flag (no RT.checkSpecAsserts, use atom)
    \\(def ^:private check-asserts-flag (atom false))
    \\
    \\(defn check-asserts?
    \\  "Returns the value set by check-asserts."
    \\  []
    \\  @check-asserts-flag)
    \\
    \\(defn check-asserts
    \\  "Enable or disable spec asserts."
    \\  [flag]
    \\  (reset! check-asserts-flag flag))
    \\
    \\(defn assert*
    \\  "Do not call this directly, use 'assert'."
    \\  [spec x]
    \\  (if (valid? spec x)
    \\    x
    \\    (let [ed (c/merge (assoc (explain-data* spec [] [] [] x)
    \\                             ::failure :assertion-failed))]
    \\      (throw (ex-info
    \\              (str "Spec assertion failed\n" (with-out-str (explain-out ed)))
    \\              ed)))))
    \\
    \\(defmacro assert
    \\  "spec-checking assert expression. Returns x if x is valid? according
    \\to spec, else throws an ex-info with explain-data plus ::failure of
    \\:assertion-failed."
    \\  [spec x]
    \\  (if *compile-asserts*
    \\    `(if (check-asserts?)
    \\       (assert* ~spec ~x)
    \\       ~x)
    \\    x))
    \\
    \\;;--- int-in, double-in, inst-in ---
    \\
    \\(defn int-in-range?
    \\  "Return true if start <= val, val < end and val is a fixed
    \\  precision integer."
    \\  [start end val]
    \\  (c/and (int? val) (<= start val) (< val end)))
    \\
    \\(defmacro int-in
    \\  "Returns a spec that validates fixed precision integers in the
    \\  range from start (inclusive) to end (exclusive)."
    \\  [start end]
    \\  `(spec (and int? #(int-in-range? ~start ~end %))))
    \\
    \\;; CLJW: double-in uses CW's double? and math predicates
    \\(defmacro double-in
    \\  "Specs a 64-bit floating point number."
    \\  [& {:keys [infinite? NaN? min max]
    \\      :or {infinite? true NaN? true}
    \\      :as m}]
    \\  `(spec (and c/double?
    \\              ~@(when-not infinite? ['#(not (Double/isInfinite %))])
    \\              ~@(when-not NaN? ['#(not (Double/isNaN %))])
    \\              ~@(when max [`#(<= % ~max)])
    \\              ~@(when min [`#(<= ~min %)]))))
    \\
    \\;; CLJW: inst-in — CW doesn't have java.util.Date, stub for API compat
    \\(defn inst-in-range?
    \\  "Return true if inst at or after start and before end"
    \\  [start end inst]
    \\  ;; CLJW: stub — inst types not yet available
    \\  false)
    \\
    \\(defmacro inst-in
    \\  "Returns a spec that validates insts in the range from start
    \\  (inclusive) to end (exclusive)."
    \\  [start end]
    \\  ;; CLJW: stub — inst types not yet available; ~'clojure.spec.alpha/and — see int-in comment
    \\  `(spec (~'clojure.spec.alpha/and inst? #(inst-in-range? ~start ~end %))))
    \\
    \\;;--- exercise, exercise-fn ---
    \\
    \\(defn exercise
    \\  "generates a number of values compatible with spec and maps conform over them,
    \\  returning a sequence of [val conformed-val] pairs. Optionally takes
    \\  a generator overrides map as per gen"
    \\  ([spec] (exercise spec 10))
    \\  ([spec n] (exercise spec n nil))
    \\  ([spec n overrides]
    \\   (map (fn [_] (let [s (gensub spec overrides [] {::recursion-limit *recursion-limit*} spec)]
    \\                  (let [v (gen/generate s)]
    \\                    [v (conform spec v)])))
    \\        (range n))))
    \\
    \\(defn exercise-fn
    \\  "exercises the fn named by sym (a symbol) by applying it to
    \\  n (default 10) generated samples of its args spec returning a sequence of
    \\  [args ret] tuples. Optionally takes a generator overrides map as per gen"
    \\  ([sym] (exercise-fn sym 10))
    \\  ([sym n] (exercise-fn sym n nil))
    \\  ([sym n fspec]
    \\   (let [f @(resolve sym)
    \\         spec (c/or fspec (get-spec sym))]
    \\     (if spec
    \\       (let [g (gen (:args spec))]
    \\         (map (fn [_]
    \\                (let [args (gen/generate g)]
    \\                  [args (apply f args)]))
    \\              (range n)))
    \\       (throw (ex-info "No fspec found" {:sym sym}))))))
;

/// Hot core function definitions re-evaluated via VM compiler after bootstrap (24C.5b, D73).
///
/// Two-phase bootstrap problem: core.clj is loaded via TreeWalk for fast startup
/// (~10ms). But this means transducer factories (map, filter, comp) return
/// TreeWalk closures. When these closures are called from a VM reduce loop,
/// each call goes through treewalkCallBridge — creating a new TreeWalk evaluator
/// per invocation (~200x slower than native VM dispatch).
///
/// Solution: After TreeWalk bootstrap, re-define only the hot-path functions
/// via the VM compiler. The transducer 1-arity forms (which return step functions
/// used inside reduce) are bytecoded; other arities delegate to the original
/// TreeWalk versions to minimize bytecode footprint and startup time.
///
/// Also includes get-in/assoc-in/update-in which delegate to Zig builtins
/// (__zig-get-in, __zig-assoc-in, __zig-update-in) for single-call path traversal.
///
/// Impact: transduce 2134ms -> 15ms (142x).
pub const hot_core_defs =
    // map, filter, comp: transducer arity returns bytecode closures.
    \\(defn filter
    \\  ([pred]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result] (rf result))
    \\       ([result input]
    \\        (if (pred input)
    \\          (rf result input)
    \\          result)))))
    \\  ([pred coll]
    \\   (__zig-lazy-filter pred coll)))
    \\(defn comp
    \\  ([] identity)
    \\  ([f] f)
    \\  ([f g]
    \\   (fn
    \\     ([] (f (g)))
    \\     ([x] (f (g x)))
    \\     ([x y] (f (g x y)))
    \\     ([x y z] (f (g x y z)))
    \\     ([x y z & args] (f (apply g x y z args)))))
    \\  ([f g & fs]
    \\   (reduce comp (list* f g fs))))
    \\(defn map
    \\  ([f]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result] (rf result))
    \\       ([result input]
    \\        (rf result (f input))))))
    \\  ([f coll]
    \\   (__zig-lazy-map f coll))
    \\  ([f c1 c2]
    \\   (lazy-seq
    \\    (let [s1 (seq c1) s2 (seq c2)]
    \\      (when (and s1 s2)
    \\        (cons (f (first s1) (first s2))
    \\              (map f (rest s1) (rest s2)))))))
    \\  ([f c1 c2 c3]
    \\   (lazy-seq
    \\    (let [s1 (seq c1) s2 (seq c2) s3 (seq c3)]
    \\      (when (and s1 s2 s3)
    \\        (cons (f (first s1) (first s2) (first s3))
    \\              (map f (rest s1) (rest s2) (rest s3)))))))
    \\  ([f c1 c2 c3 & colls]
    \\   (let [step (fn step [cs]
    \\                (lazy-seq
    \\                 (let [ss (map seq cs)]
    \\                   (when (every? identity ss)
    \\                     (cons (map first ss) (step (map rest ss)))))))]
    \\     (map #(apply f %) (step (conj colls c3 c2 c1))))))
    \\(defn get-in
    \\  ([m ks] (__zig-get-in m ks))
    \\  ([m ks not-found] (__zig-get-in m ks not-found)))
    \\(defn assoc-in [m ks v] (__zig-assoc-in m ks v))
    \\(defn update-in
    \\  ([m ks f] (__zig-update-in m ks f))
    \\  ([m ks f a] (__zig-update-in m ks f a))
    \\  ([m ks f a b] (__zig-update-in m ks f a b))
    \\  ([m ks f a b c] (__zig-update-in m ks f a b c))
    \\  ([m ks f a b c & args] (apply __zig-update-in m ks f a b c args)))
;

/// Higher-order functions that return Clojure closures.
/// These cannot be Zig builtin_fn (bare function pointers with no captured state).
/// Evaluated via VM bootstrap alongside hot_core_defs, producing bytecoded closures.
/// Order matters: preserving-reduced before cat, complement before remove.
pub const core_hof_defs =
    \\(defn constantly [x]
    \\  (fn [& args] x))
    \\(defn complement [f]
    \\  (fn [& args]
    \\    (not (apply f args))))
    \\(defn partial
    \\  ([f] f)
    \\  ([f arg1]
    \\   (fn
    \\     ([] (f arg1))
    \\     ([x] (f arg1 x))
    \\     ([x y] (f arg1 x y))
    \\     ([x y z] (f arg1 x y z))
    \\     ([x y z & args] (apply f arg1 x y z args))))
    \\  ([f arg1 arg2]
    \\   (fn
    \\     ([] (f arg1 arg2))
    \\     ([x] (f arg1 arg2 x))
    \\     ([x y] (f arg1 arg2 x y))
    \\     ([x y z] (f arg1 arg2 x y z))
    \\     ([x y z & args] (apply f arg1 arg2 x y z args))))
    \\  ([f arg1 arg2 arg3]
    \\   (fn
    \\     ([] (f arg1 arg2 arg3))
    \\     ([x] (f arg1 arg2 arg3 x))
    \\     ([x y] (f arg1 arg2 arg3 x y))
    \\     ([x y z] (f arg1 arg2 arg3 x y z))
    \\     ([x y z & args] (apply f arg1 arg2 arg3 x y z args))))
    \\  ([f arg1 arg2 arg3 & more]
    \\   (fn [& args] (apply f arg1 arg2 arg3 (concat more args)))))
    \\(defn juxt
    \\  ([f]
    \\   (fn
    \\     ([] [(f)])
    \\     ([x] [(f x)])
    \\     ([x y] [(f x y)])
    \\     ([x y z] [(f x y z)])
    \\     ([x y z & args] [(apply f x y z args)])))
    \\  ([f g]
    \\   (fn
    \\     ([] [(f) (g)])
    \\     ([x] [(f x) (g x)])
    \\     ([x y] [(f x y) (g x y)])
    \\     ([x y z] [(f x y z) (g x y z)])
    \\     ([x y z & args] [(apply f x y z args) (apply g x y z args)])))
    \\  ([f g h]
    \\   (fn
    \\     ([] [(f) (g) (h)])
    \\     ([x] [(f x) (g x) (h x)])
    \\     ([x y] [(f x y) (g x y) (h x y)])
    \\     ([x y z] [(f x y z) (g x y z) (h x y z)])
    \\     ([x y z & args] [(apply f x y z args) (apply g x y z args) (apply h x y z args)])))
    \\  ([f g h & fs]
    \\   (let [fs (list* f g h fs)]
    \\     (fn
    \\       ([] (reduce #(conj %1 (%2)) [] fs))
    \\       ([x] (reduce #(conj %1 (%2 x)) [] fs))
    \\       ([x y] (reduce #(conj %1 (%2 x y)) [] fs))
    \\       ([x y z] (reduce #(conj %1 (%2 x y z)) [] fs))
    \\       ([x y z & args] (reduce #(conj %1 (apply %2 x y z args)) [] fs))))))
    \\(defn every-pred
    \\  ([p]
    \\   (fn ep1
    \\     ([] true)
    \\     ([x] (boolean (p x)))
    \\     ([x y] (boolean (and (p x) (p y))))
    \\     ([x y z] (boolean (and (p x) (p y) (p z))))
    \\     ([x y z & args] (boolean (and (ep1 x y z)
    \\                                   (every? p args))))))
    \\  ([p1 p2]
    \\   (fn ep2
    \\     ([] true)
    \\     ([x] (boolean (and (p1 x) (p2 x))))
    \\     ([x y] (boolean (and (p1 x) (p1 y) (p2 x) (p2 y))))
    \\     ([x y z] (boolean (and (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z))))
    \\     ([x y z & args] (boolean (and (ep2 x y z)
    \\                                   (every? #(and (p1 %) (p2 %)) args))))))
    \\  ([p1 p2 p3]
    \\   (fn ep3
    \\     ([] true)
    \\     ([x] (boolean (and (p1 x) (p2 x) (p3 x))))
    \\     ([x y] (boolean (and (p1 x) (p1 y) (p2 x) (p2 y) (p3 x) (p3 y))))
    \\     ([x y z] (boolean (and (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z) (p3 x) (p3 y) (p3 z))))
    \\     ([x y z & args] (boolean (and (ep3 x y z)
    \\                                   (every? #(and (p1 %) (p2 %) (p3 %)) args))))))
    \\  ([p1 p2 p3 & ps]
    \\   (let [ps (list* p1 p2 p3 ps)]
    \\     (fn epn
    \\       ([] true)
    \\       ([x] (every? #(% x) ps))
    \\       ([x y] (every? #(and (% x) (% y)) ps))
    \\       ([x y z] (every? #(and (% x) (% y) (% z)) ps))
    \\       ([x y z & args] (boolean (and (epn x y z)
    \\                                     (every? #(every? % args) ps))))))))
    \\(defn some-fn
    \\  ([p]
    \\   (fn sp1
    \\     ([] nil)
    \\     ([x] (p x))
    \\     ([x y] (or (p x) (p y)))
    \\     ([x y z] (or (p x) (p y) (p z)))
    \\     ([x y z & args] (or (sp1 x y z)
    \\                         (some p args)))))
    \\  ([p1 p2]
    \\   (fn sp2
    \\     ([] nil)
    \\     ([x] (or (p1 x) (p2 x)))
    \\     ([x y] (or (p1 x) (p1 y) (p2 x) (p2 y)))
    \\     ([x y z] (or (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z)))
    \\     ([x y z & args] (or (sp2 x y z)
    \\                         (some #(or (p1 %) (p2 %)) args)))))
    \\  ([p1 p2 p3]
    \\   (fn sp3
    \\     ([] nil)
    \\     ([x] (or (p1 x) (p2 x) (p3 x)))
    \\     ([x y] (or (p1 x) (p1 y) (p2 x) (p2 y) (p3 x) (p3 y)))
    \\     ([x y z] (or (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z) (p3 x) (p3 y) (p3 z)))
    \\     ([x y z & args] (or (sp3 x y z)
    \\                         (some #(or (p1 %) (p2 %) (p3 %)) args)))))
    \\  ([p1 p2 p3 & ps]
    \\   (let [ps (list* p1 p2 p3 ps)]
    \\     (fn spn
    \\       ([] nil)
    \\       ([x] (some #(% x) ps))
    \\       ([x y] (some #(or (% x) (% y)) ps))
    \\       ([x y z] (some #(or (% x) (% y) (% z)) ps))
    \\       ([x y z & args] (or (spn x y z)
    \\                           (some #(some % args) ps)))))))
    \\(defn fnil
    \\  ([f x]
    \\   (fn
    \\     ([a] (f (if (nil? a) x a)))
    \\     ([a b] (f (if (nil? a) x a) b))
    \\     ([a b c] (f (if (nil? a) x a) b c))
    \\     ([a b c & ds] (apply f (if (nil? a) x a) b c ds))))
    \\  ([f x y]
    \\   (fn
    \\     ([a b] (f (if (nil? a) x a) (if (nil? b) y b)))
    \\     ([a b c] (f (if (nil? a) x a) (if (nil? b) y b) c))
    \\     ([a b c & ds] (apply f (if (nil? a) x a) (if (nil? b) y b) c ds))))
    \\  ([f x y z]
    \\   (fn
    \\     ([a b] (f (if (nil? a) x a) (if (nil? b) y b)))
    \\     ([a b c] (f (if (nil? a) x a) (if (nil? b) y b) (if (nil? c) z c)))
    \\     ([a b c & ds] (apply f (if (nil? a) x a) (if (nil? b) y b) (if (nil? c) z c) ds)))))
    \\(defn memoize [f]
    \\  (let [mem (atom {})]
    \\    (fn [& args]
    \\      (if-let [e (find (deref mem) args)]
    \\        (val e)
    \\        (let [ret (apply f args)]
    \\          (swap! mem assoc args ret)
    \\          ret)))))
    \\(defn bound-fn*
    \\  [f]
    \\  (let [bindings (get-thread-bindings)]
    \\    (fn [& args]
    \\      (apply with-bindings* bindings f args))))
    \\(defn completing
    \\  ([f] (completing f identity))
    \\  ([f cf]
    \\   (fn
    \\     ([] (f))
    \\     ([x] (cf x))
    \\     ([x y] (f x y)))))
    \\(defn comparator [pred]
    \\  (fn [x y]
    \\    (cond (pred x y) -1 (pred y x) 1 :else 0)))
    \\(defn accessor [s key]
    \\  (fn [m] (get m key)))
    \\(defn- preserving-reduced [rf]
    \\  (fn [a b]
    \\    (let [ret (rf a b)]
    \\      (if (reduced? ret)
    \\        (reduced ret)
    \\        ret))))
    \\(defn cat [rf]
    \\  (let [rrf (preserving-reduced rf)]
    \\    (fn
    \\      ([] (rf))
    \\      ([result] (rf result))
    \\      ([result input]
    \\       (reduce rrf result input)))))
    \\(defn halt-when
    \\  ([pred] (halt-when pred nil))
    \\  ([pred retf]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result]
    \\        (if (and (map? result) (contains? result ::halt))
    \\          (::halt result)
    \\          (rf result)))
    \\       ([result input]
    \\        (if (pred input)
    \\          (reduced {::halt (if retf (retf (rf result) input) input)})
    \\          (rf result input)))))))
    \\(defn dedupe
    \\  ([]
    \\   (fn [rf]
    \\     (let [pv (volatile! ::none)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [prior @pv]
    \\            (vreset! pv input)
    \\            (if (= prior input)
    \\              result
    \\              (rf result input))))))))
    \\  ([coll] (sequence (dedupe) coll)))
    \\(defn remove
    \\  ([pred] (filter (complement pred)))
    \\  ([pred coll]
    \\   (filter (complement pred) coll)))
;

/// Remaining core.clj functions: transducers, lazy-seq constructors, def constants,
/// destructure, pmap, etc. Evaluated after core_hof_defs.
pub const core_seq_defs =
    \\(defn concat
    \\  ([] (lazy-seq nil))
    \\  ([x] (lazy-seq x))
    \\  ([x y]
    \\   (lazy-seq
    \\    (let [s (seq x)]
    \\      (if s
    \\        (cons (first s) (concat (rest s) y))
    \\        y))))
    \\  ([x y & zs]
    \\   (let [cat (fn cat [xy zs]
    \\               (lazy-seq
    \\                (let [s (seq xy)]
    \\                  (if s
    \\                    (cons (first s) (cat (rest s) zs))
    \\                    (when zs
    \\                      (cat (first zs) (next zs)))))))]
    \\     (cat (concat x y) zs))))
    \\(defn iterate [f x]
    \\  (__zig-lazy-iterate f x))
    \\(defn range
    \\  ([] (iterate inc 0))
    \\  ([end] (range 0 end 1))
    \\  ([start end] (range start end 1))
    \\  ([start end step]
    \\   (if (and (integer? start) (integer? end) (integer? step))
    \\     (__zig-lazy-range start end step)
    \\     (lazy-seq
    \\      (cond
    \\        (and (pos? step) (< start end))
    \\        (cons start (range (+ start step) end step))
    \\        (and (neg? step) (> start end))
    \\        (cons start (range (+ start step) end step)))))))
    \\(defn repeat
    \\  ([x] (lazy-seq (cons x (repeat x))))
    \\  ([n x]
    \\   (take n (repeat x))))
    \\(defn repeatedly
    \\  ([f] (lazy-seq (cons (f) (repeatedly f))))
    \\  ([n f] (take n (repeatedly f))))
    \\(defn take
    \\  ([n]
    \\   (fn [rf]
    \\     (let [nv (volatile! n)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [cur @nv
    \\                nxt (vswap! nv dec)
    \\                res (if (pos? cur)
    \\                      (rf result input)
    \\                      result)]
    \\            (if (not (pos? nxt))
    \\              (ensure-reduced res)
    \\              res)))))))
    \\  ([n coll]
    \\   (__zig-lazy-take n coll)))
    \\(defn drop
    \\  ([n]
    \\   (fn [rf]
    \\     (let [nv (volatile! n)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [cur @nv]
    \\            (vswap! nv dec)
    \\            (if (pos? cur)
    \\              result
    \\              (rf result input))))))))
    \\  ([n coll]
    \\   (lazy-seq
    \\    (loop [i n s (seq coll)]
    \\      (if (if (> i 0) s nil)
    \\        (recur (- i 1) (next s))
    \\        s)))))
    \\(defn lazy-cat-helper [colls]
    \\  (when (seq colls)
    \\    (lazy-seq
    \\     (let [c (first colls)]
    \\       (if (seq c)
    \\         (cons (first c) (lazy-cat-helper (cons (rest c) (rest colls))))
    \\         (lazy-cat-helper (rest colls)))))))
    \\(defn cycle [coll]
    \\  (when (seq coll)
    \\    (lazy-seq
    \\     (lazy-cat-helper (repeat coll)))))
    \\(defn interleave
    \\  ([] (list))
    \\  ([c1] (lazy-seq c1))
    \\  ([c1 c2]
    \\   (lazy-seq
    \\    (let [s1 (seq c1) s2 (seq c2)]
    \\      (when (and s1 s2)
    \\        (cons (first s1) (cons (first s2)
    \\                               (interleave (rest s1) (rest s2))))))))
    \\  ([c1 c2 & colls]
    \\   (lazy-seq
    \\    (let [ss (map seq (cons c1 (cons c2 colls)))]
    \\      (when (every? identity ss)
    \\        (concat (map first ss) (apply interleave (map rest ss))))))))
    \\(defn interpose
    \\  ([sep]
    \\   (fn [rf]
    \\     (let [started (volatile! false)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (if @started
    \\            (let [sepr (rf result sep)]
    \\              (if (reduced? sepr)
    \\                sepr
    \\                (rf sepr input)))
    \\            (do
    \\              (vreset! started true)
    \\              (rf result input))))))))
    \\  ([sep coll]
    \\   (drop 1 (interleave (repeat sep) coll))))
    \\(defn partition
    \\  ([n coll]
    \\   (partition n n coll))
    \\  ([n step coll]
    \\   (loop [s (seq coll) acc (list)]
    \\     (let [chunk (take n s)]
    \\       (if (= (count chunk) n)
    \\         (recur (drop step s) (cons chunk acc))
    \\         (reverse acc)))))
    \\  ([n step pad coll]
    \\   (loop [s (seq coll) acc (list)]
    \\     (let [chunk (take n s)]
    \\       (if (= (count chunk) n)
    \\         (recur (drop step s) (cons chunk acc))
    \\         (if (seq chunk)
    \\           (reverse (cons (take n (concat chunk pad)) acc))
    \\           (reverse acc)))))))
    \\(defn partition-by
    \\  ([f]
    \\   (fn [rf]
    \\     (let [a (volatile! [])
    \\           pv (volatile! ::none)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result]
    \\          (let [result (if (zero? (count @a))
    \\                         result
    \\                         (let [v @a]
    \\                           (vreset! a [])
    \\                           (unreduced (rf result v))))]
    \\            (rf result)))
    \\         ([result input]
    \\          (let [pval @pv
    \\                val (f input)]
    \\            (vreset! pv val)
    \\            (if (or (identical? pval ::none)
    \\                    (= val pval))
    \\              (do (vswap! a conj input)
    \\                  result)
    \\              (let [v @a]
    \\                (vreset! a [])
    \\                (let [ret (rf result v)]
    \\                  (when-not (reduced? ret)
    \\                    (vswap! a conj input))
    \\                  ret)))))))))
    \\  ([f coll]
    \\   (loop [s (seq coll) acc (list) cur (list) prev nil started false]
    \\     (if s
    \\       (let [v (first s)
    \\             fv (f v)]
    \\         (if (if started (= fv prev) true)
    \\           (recur (next s) acc (cons v cur) fv true)
    \\           (recur (next s) (cons (reverse cur) acc) (list v) fv true)))
    \\       (if (seq cur)
    \\         (reverse (cons (reverse cur) acc))
    \\         (reverse acc))))))
    \\(defn distinct
    \\  ([]
    \\   (fn [rf]
    \\     (let [seen (volatile! #{})]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (if (contains? @seen input)
    \\            result
    \\            (do (vswap! seen conj input)
    \\                (rf result input))))))))
    \\  ([coll]
    \\   (loop [s (seq coll) seen #{} acc (list)]
    \\     (if s
    \\       (let [x (first s)]
    \\         (if (contains? seen x)
    \\           (recur (next s) seen acc)
    \\           (recur (next s) (conj seen x) (cons x acc))))
    \\       (reverse acc)))))
    \\(defn mapcat
    \\  ([f] (comp (map f) cat))
    \\  ([f coll]
    \\   ((fn step [cur remaining]
    \\      (lazy-seq
    \\       (if (seq cur)
    \\         (cons (first cur) (step (rest cur) remaining))
    \\         (let [s (seq remaining)]
    \\           (when s
    \\             (step (f (first s)) (rest s)))))))
    \\    nil coll))
    \\  ([f c1 c2]
    \\   (apply concat (map f c1 c2)))
    \\  ([f c1 c2 c3]
    \\   (apply concat (map f c1 c2 c3))))
    \\(defn map-indexed
    \\  ([f]
    \\   (fn [rf]
    \\     (let [i (volatile! -1)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (rf result (f (vswap! i inc) input)))))))
    \\  ([f coll]
    \\   (loop [s (seq coll) i 0 acc (list)]
    \\     (if s
    \\       (recur (next s) (+ i 1) (cons (f i (first s)) acc))
    \\       (reverse acc)))))
    \\(defn keep
    \\  ([f]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result] (rf result))
    \\       ([result input]
    \\        (let [v (f input)]
    \\          (if (nil? v)
    \\            result
    \\            (rf result v)))))))
    \\  ([f coll]
    \\   (lazy-seq
    \\    (when-let [s (seq coll)]
    \\      (if (chunked-seq? s)
    \\        (let [c (chunk-first s)
    \\              size (count c)
    \\              b (chunk-buffer size)]
    \\          (loop [i 0]
    \\            (when (< i size)
    \\              (let [x (f (nth c i))]
    \\                (when-not (nil? x)
    \\                  (chunk-append b x)))
    \\              (recur (inc i))))
    \\          (chunk-cons (chunk b) (keep f (chunk-rest s))))
    \\        (let [x (f (first s))]
    \\          (if (nil? x)
    \\            (keep f (rest s))
    \\            (cons x (keep f (rest s))))))))))
    \\(defn keep-indexed
    \\  ([f]
    \\   (fn [rf]
    \\     (let [iv (volatile! -1)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [i (vswap! iv inc)
    \\                v (f i input)]
    \\            (if (nil? v)
    \\              result
    \\              (rf result v))))))))
    \\  ([f coll]
    \\   (loop [s (seq coll) i 0 acc (list)]
    \\     (if s
    \\       (let [v (f i (first s))]
    \\         (if (nil? v)
    \\           (recur (next s) (+ i 1) acc)
    \\           (recur (next s) (+ i 1) (cons v acc))))
    \\       (reverse acc)))))
    \\(defn partition-all
    \\  ([n]
    \\   (fn [rf]
    \\     (let [a (volatile! [])]
    \\       (fn
    \\         ([] (rf))
    \\         ([result]
    \\          (let [result (if (zero? (count @a))
    \\                         result
    \\                         (let [v @a]
    \\                           (vreset! a [])
    \\                           (unreduced (rf result v))))]
    \\            (rf result)))
    \\         ([result input]
    \\          (vswap! a conj input)
    \\          (if (= n (count @a))
    \\            (let [v @a]
    \\              (vreset! a [])
    \\              (rf result v))
    \\            result))))))
    \\  ([n coll]
    \\   (loop [s (seq coll) acc (list)]
    \\     (let [chunk (take n s)]
    \\       (if (seq chunk)
    \\         (recur (drop n s) (cons chunk acc))
    \\         (reverse acc))))))
    \\(defn take-while
    \\  ([pred]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result] (rf result))
    \\       ([result input]
    \\        (if (pred input)
    \\          (rf result input)
    \\          (reduced result))))))
    \\  ([pred coll]
    \\   (lazy-seq
    \\    (let [s (seq coll)]
    \\      (when s
    \\        (when (pred (first s))
    \\          (cons (first s) (take-while pred (rest s)))))))))
    \\(defn drop-while
    \\  ([pred]
    \\   (fn [rf]
    \\     (let [dv (volatile! true)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [drop? @dv]
    \\            (if (and drop? (pred input))
    \\              result
    \\              (do
    \\                (vreset! dv nil)
    \\                (rf result input)))))))))
    \\  ([pred coll]
    \\   (loop [s (seq coll)]
    \\     (if s
    \\       (if (pred (first s))
    \\         (recur (next s))
    \\         s)
    \\       (list)))))
    \\(defn take-nth
    \\  ([n]
    \\   (fn [rf]
    \\     (let [iv (volatile! -1)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [i (vswap! iv inc)]
    \\            (if (zero? (rem i n))
    \\              (rf result input)
    \\              result)))))))
    \\  ([n coll]
    \\   (lazy-seq
    \\    (when-let [s (seq coll)]
    \\      (cons (first s) (take-nth n (drop n s)))))))
    \\(defn replace
    \\  ([smap]
    \\   (map (fn [x] (if-let [e (find smap x)] (val e) x))))
    \\  ([smap coll]
    \\   (if (vector? coll)
    \\     (reduce (fn [v i]
    \\               (if-let [e (find smap (nth v i))]
    \\                 (assoc v i (val e))
    \\                 v))
    \\             coll (range (count coll)))
    \\     (map (fn [x] (if-let [e (find smap x)] (val e) x)) coll))))
    \\(defn random-sample
    \\  ([prob]
    \\   (filter (fn [_] (< (rand) prob))))
    \\  ([prob coll]
    \\   (filter (fn [_] (< (rand) prob)) coll)))
    \\(defn reductions
    \\  ([f coll]
    \\   (lazy-seq
    \\    (if-let [s (seq coll)]
    \\      (reductions f (first s) (rest s))
    \\      (list (f)))))
    \\  ([f init coll]
    \\   (if (reduced? init)
    \\     (list @init)
    \\     (cons init
    \\           (lazy-seq
    \\            (when-let [s (seq coll)]
    \\              (reductions f (f init (first s)) (rest s))))))))
    \\(defn tree-seq
    \\  [branch? children root]
    \\  (let [walk (fn walk [node]
    \\               (lazy-seq
    \\                (cons node
    \\                      (when (branch? node)
    \\                        (mapcat walk (children node))))))]
    \\    (walk root)))
    \\(defn xml-seq
    \\  [root]
    \\  (tree-seq
    \\   (complement string?)
    \\   (comp seq :content)
    \\   root))
    \\(defn iteration
    \\  [step & {:keys [somef vf kf initk]
    \\           :or {vf identity
    \\                kf identity
    \\                somef some?
    \\                initk nil}}]
    \\  ((fn next [ret]
    \\     (when (somef ret)
    \\       (cons (vf ret)
    \\             (when-some [k (kf ret)]
    \\               (lazy-seq (next (step k)))))))
    \\   (step initk)))
    \\(defn partitionv
    \\  ([n coll] (partitionv n n coll))
    \\  ([n step coll]
    \\   (lazy-seq
    \\    (let [s (seq coll)
    \\          p (vec (take n s))]
    \\      (when (= n (count p))
    \\        (cons p (partitionv n step (nthrest s step)))))))
    \\  ([n step pad coll]
    \\   (lazy-seq
    \\    (let [s (seq coll)
    \\          p (vec (take n s))]
    \\      (if (= n (count p))
    \\        (cons p (partitionv n step pad (nthrest s step)))
    \\        (when (seq p)
    \\          (list (vec (take n (concat p pad))))))))))
    \\(defn partitionv-all
    \\  ([n coll] (partitionv-all n n coll))
    \\  ([n step coll]
    \\   (lazy-seq
    \\    (let [s (seq coll)]
    \\      (when s
    \\        (let [p (vec (take n s))]
    \\          (cons p (partitionv-all n step (nthrest s step)))))))))
    \\(defn pmap
    \\  ([f coll]
    \\   (let [n (+ 2 (__available-processors))
    \\         rets (map (fn [x] (future (f x))) coll)
    \\         step (fn step [[x & xs :as vs] fs]
    \\                (lazy-seq
    \\                 (if-let [s (seq fs)]
    \\                   (cons (deref x) (step xs (rest s)))
    \\                   (map deref vs))))]
    \\     (step rets (drop n rets))))
    \\  ([f coll & colls]
    \\   (let [step (fn step [cs]
    \\                (lazy-seq
    \\                 (let [ss (map seq cs)]
    \\                   (when (every? identity ss)
    \\                     (cons (map first ss) (step (map rest ss)))))))]
    \\     (pmap (fn [args] (apply f args)) (step (cons coll colls))))))
    \\(defn pcalls
    \\  [& fns] (pmap (fn [f] (f)) fns))
    \\(defn- parse-impls [specs]
    \\  (loop [ret {} s specs]
    \\    (if (seq s)
    \\      (recur (assoc ret (first s) (take-while seq? (next s)))
    \\             (drop-while seq? (next s)))
    \\      ret)))
    \\(defn destructure [bindings]
    \\  (let [bents (partition 2 bindings)
    \\        pb (fn pb [bvec b v]
    \\             (let [pvec
    \\                   (fn [bvec b val]
    \\                     (let [gvec (gensym "vec__")
    \\                           gseq (gensym "seq__")
    \\                           gfirst (gensym "first__")
    \\                           has-rest (some #{'&} b)]
    \\                       (loop [ret (let [ret (conj bvec gvec val)]
    \\                                    (if has-rest
    \\                                      (conj ret gseq (list `seq gvec))
    \\                                      ret))
    \\                              n 0
    \\                              bs b
    \\                              seen-rest? false]
    \\                         (if (seq bs)
    \\                           (let [firstb (first bs)]
    \\                             (cond
    \\                               (= firstb '&) (recur (pb ret (second bs) gseq)
    \\                                                    n
    \\                                                    (nnext bs)
    \\                                                    true)
    \\                               (= firstb :as) (pb ret (second bs) gvec)
    \\                               :else (if seen-rest?
    \\                                       (throw (ex-info "Unsupported binding form, only :as can follow & parameter" {}))
    \\                                       (recur (pb (if has-rest
    \\                                                    (conj ret
    \\                                                          gfirst `(first ~gseq)
    \\                                                          gseq `(next ~gseq))
    \\                                                    ret)
    \\                                                  firstb
    \\                                                  (if has-rest
    \\                                                    gfirst
    \\                                                    (list `nth gvec n nil)))
    \\                                              (inc n)
    \\                                              (next bs)
    \\                                              seen-rest?))))
    \\                           ret))))
    \\                   pmap
    \\                   (fn [bvec b v]
    \\                     (let [gmap (gensym "map__")
    \\                           defaults (:or b)]
    \\                       (loop [ret (-> bvec (conj gmap) (conj v)
    \\                                      (conj gmap) (conj `(if (seq? ~gmap)
    \\                                                           (seq-to-map-for-destructuring ~gmap)
    \\                                                           ~gmap))
    \\                                      ((fn [ret]
    \\                                         (if (:as b)
    \\                                           (conj ret (:as b) gmap)
    \\                                           ret))))
    \\                              bes (let [transforms
    \\                                        (reduce
    \\                                         (fn [transforms mk]
    \\                                           (if (keyword? mk)
    \\                                             (let [mkns (namespace mk)
    \\                                                   mkn (name mk)]
    \\                                               (cond (= mkn "keys") (assoc transforms mk #(keyword (or mkns (namespace %)) (name %)))
    \\                                                     (= mkn "syms") (assoc transforms mk #(list `quote (symbol (or mkns (namespace %)) (name %))))
    \\                                                     (= mkn "strs") (assoc transforms mk str)
    \\                                                     :else transforms))
    \\                                             transforms))
    \\                                         {}
    \\                                         (keys b))]
    \\                                    (reduce
    \\                                     (fn [bes entry]
    \\                                       (reduce #(assoc %1 %2 ((val entry) %2))
    \\                                               (dissoc bes (key entry))
    \\                                               ((key entry) bes)))
    \\                                     (dissoc b :as :or)
    \\                                     transforms))]
    \\                         (if (seq bes)
    \\                           (let [bb (key (first bes))
    \\                                 bk (val (first bes))
    \\                                 local (if (ident? bb) (with-meta (symbol nil (name bb)) (meta bb)) bb)
    \\                                 bv (if (contains? defaults local)
    \\                                      (list `get gmap bk (defaults local))
    \\                                      (list `get gmap bk))]
    \\                             (recur (if (ident? bb)
    \\                                      (-> ret (conj local bv))
    \\                                      (pb ret bb bv))
    \\                                    (next bes)))
    \\                           ret))))]
    \\               (cond
    \\                 (symbol? b) (-> bvec (conj b) (conj v))
    \\                 (vector? b) (pvec bvec b v)
    \\                 (map? b) (pmap bvec b v)
    \\                 :else (throw (ex-info (str "Unsupported binding form: " b) {})))))
    \\        process-entry (fn [bvec b] (pb bvec (first b) (second b)))]
    \\    (if (every? symbol? (map first bents))
    \\      bindings
    \\      (reduce process-entry [] bents))))
    \\(def String 'String)
    \\(def Character 'Character)
    \\(def Number 'Number)
    \\(def Integer 'Integer)
    \\(def Long 'Long)
    \\(def Double 'Double)
    \\(def Float 'Float)
    \\(def Boolean 'Boolean)
    \\(def Object 'Object)
    \\(def Throwable 'Throwable)
    \\(def Exception 'Exception)
    \\(def RuntimeException 'RuntimeException)
    \\(def Comparable 'Comparable)
    \\(def ^:dynamic *math-context* nil)
    \\(def *assert* true)
    \\(def ^:private global-hierarchy (make-hierarchy))
    \\(def *clojure-version*
    \\  {:major 1 :minor 12 :incremental 0 :qualifier nil})
    \\(def ^:dynamic *warn-on-reflection* false)
    \\(def ^:dynamic *agent* nil)
    \\(def ^:dynamic *allow-unresolved-vars* false)
    \\(def ^:dynamic *reader-resolver* nil)
    \\(def ^:dynamic *suppress-read* false)
    \\(def ^:dynamic *compile-path* nil)
    \\(def ^:dynamic *fn-loader* nil)
    \\(def ^:dynamic *use-context-classloader* true)
    \\(def char-escape-string
    \\  {\newline "\\n"
    \\   \tab     "\\t"
    \\   \return  "\\r"
    \\   \"       "\\\""
    \\   \\       "\\\\"
    \\   \formfeed "\\f"
    \\   \backspace "\\b"})
    \\(def char-name-string
    \\  {\newline  "newline"
    \\   \tab      "tab"
    \\   \space    "space"
    \\   \backspace "backspace"
    \\   \formfeed "formfeed"
    \\   \return   "return"})
    \\(def default-data-readers
    \\  {'inst __inst-from-string
    \\   'uuid __uuid-from-string})
    \\(def *1 nil)
    \\(def *2 nil)
    \\(def *3 nil)
;
