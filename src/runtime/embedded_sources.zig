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

/// Embedded clojure/spec/gen/alpha.clj source (compiled into binary).
pub const spec_gen_alpha_clj_source = @embedFile("../clj/clojure/spec/gen/alpha.clj");

/// Embedded clojure/spec/alpha.clj source (compiled into binary).
pub const spec_alpha_clj_source = @embedFile("../clj/clojure/spec/alpha.clj");

/// Embedded clojure/core/specs/alpha.clj source (compiled into binary).
pub const core_specs_alpha_clj_source = @embedFile("../clj/clojure/core/specs/alpha.clj");


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
