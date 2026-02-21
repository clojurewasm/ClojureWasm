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

// pprint.clj replaced with Zig multiline string (Phase B.16)
// Heavy multimethod/dispatch usage; some builtins in pprint.zig.
pub const pprint_clj_source =
    \\(defn- rtrim-whitespace [s]
    \\  (let [len (count s)]
    \\    (if (zero? len)
    \\      s
    \\      (loop [n (dec len)]
    \\        (cond
    \\          (neg? n) ""
    \\          (not (Character/isWhitespace (.charAt ^String s n))) (subs s 0 (inc n))
    \\          true (recur (dec n)))))))
    \\
    \\(def ^:dynamic ^{:private true} *default-page-width* 72)
    \\
    \\(defn- column-writer
    \\  ([writer] (column-writer writer *default-page-width*))
    \\  ([writer max-columns]
    \\   (atom {:max max-columns :cur 0 :line 0 :base writer})))
    \\
    \\(defn- get-column [cw] (:cur @cw))
    \\(defn- get-max-column [cw] (:max @cw))
    \\
    \\(defn- cw-write-char [cw c]
    \\  (if (= c \newline)
    \\    (swap! cw #(-> % (assoc :cur 0) (update :line inc)))
    \\    (swap! cw update :cur inc))
    \\  (print (str c)))
    \\
    \\(defn- last-index-of-char [s c]
    \\  (loop [i (dec (count s))]
    \\    (cond
    \\      (neg? i) -1
    \\      (= (.charAt ^String s i) c) i
    \\      :else (recur (dec i)))))
    \\
    \\(defn- cw-write-string [cw s]
    \\  (let [nl (last-index-of-char s \newline)]
    \\    (if (neg? nl)
    \\      (swap! cw update :cur + (count s))
    \\      (swap! cw #(-> %
    \\                     (assoc :cur (- (count s) nl 1))
    \\                     (update :line + (count (filter (fn [ch] (= ch \newline)) s)))))))
    \\  (print s))
    \\
    \\(declare get-miser-width)
    \\
    \\(defmacro ^{:private true} getf [pw sym]
    \\  `(~sym @~pw))
    \\
    \\(defmacro ^{:private true} setf [pw sym new-val]
    \\  `(swap! ~pw assoc ~sym ~new-val))
    \\
    \\(defn- make-buffer-blob [data trailing-ws start-pos end-pos]
    \\  {:type-tag :buffer-blob :data data :trailing-white-space trailing-ws
    \\   :start-pos start-pos :end-pos end-pos})
    \\
    \\(defn- make-nl-t [type logical-block start-pos end-pos]
    \\  {:type-tag :nl-t :type type :logical-block logical-block
    \\   :start-pos start-pos :end-pos end-pos})
    \\
    \\(defn- nl-t? [x] (= (:type-tag x) :nl-t))
    \\
    \\(defn- make-start-block-t [logical-block start-pos end-pos]
    \\  {:type-tag :start-block-t :logical-block logical-block
    \\   :start-pos start-pos :end-pos end-pos})
    \\
    \\(defn- make-end-block-t [logical-block start-pos end-pos]
    \\  {:type-tag :end-block-t :logical-block logical-block
    \\   :start-pos start-pos :end-pos end-pos})
    \\
    \\(defn- make-indent-t [logical-block relative-to offset start-pos end-pos]
    \\  {:type-tag :indent-t :logical-block logical-block :relative-to relative-to
    \\   :offset offset :start-pos start-pos :end-pos end-pos})
    \\
    \\(defn- make-logical-block [parent section start-col indent done-nl intra-block-nl
    \\                           prefix per-line-prefix suffix]
    \\  {:parent parent :section section
    \\   :start-col (atom start-col) :indent (atom indent)
    \\   :done-nl (atom done-nl) :intra-block-nl (atom intra-block-nl)
    \\   :prefix prefix :per-line-prefix per-line-prefix :suffix suffix})
    \\
    \\(defn- ancestor? [parent child]
    \\  (loop [child (:parent child)]
    \\    (cond
    \\      (nil? child) false
    \\      (identical? parent child) true
    \\      :else (recur (:parent child)))))
    \\
    \\(defn- buffer-length [l]
    \\  (let [l (seq l)]
    \\    (if l
    \\      (- (:end-pos (last l)) (:start-pos (first l)))
    \\      0)))
    \\
    \\(def ^:dynamic ^{:private true} *pw* nil)
    \\
    \\(defn- pw-base-write [pw s]
    \\  (let [base (getf pw :base)]
    \\    (cw-write-string base s)))
    \\
    \\(defn- pw-base-write-char [pw c]
    \\  (let [base (getf pw :base)]
    \\    (cw-write-char base c)))
    \\
    \\(defn- pp-newline [] "\n")
    \\
    \\(declare emit-nl)
    \\
    \\(defmulti ^{:private true} write-token (fn [pw token] (:type-tag token)))
    \\
    \\(defmethod write-token :start-block-t [pw token]
    \\  (when-let [cb (getf pw :logical-block-callback)] (cb :start))
    \\  (let [lb (:logical-block token)]
    \\    (when-let [prefix (:prefix lb)]
    \\      (pw-base-write pw prefix))
    \\    (let [col (get-column (getf pw :base))]
    \\      (reset! (:start-col lb) col)
    \\      (reset! (:indent lb) col))))
    \\
    \\(defmethod write-token :end-block-t [pw token]
    \\  (when-let [cb (getf pw :logical-block-callback)] (cb :end))
    \\  (when-let [suffix (:suffix (:logical-block token))]
    \\    (pw-base-write pw suffix)))
    \\
    \\(defmethod write-token :indent-t [pw token]
    \\  (let [lb (:logical-block token)]
    \\    (reset! (:indent lb)
    \\            (+ (:offset token)
    \\               (condp = (:relative-to token)
    \\                 :block @(:start-col lb)
    \\                 :current (get-column (getf pw :base)))))))
    \\
    \\(defmethod write-token :buffer-blob [pw token]
    \\  (pw-base-write pw (:data token)))
    \\
    \\(defmethod write-token :nl-t [pw token]
    \\  (if (or (= (:type token) :mandatory)
    \\          (and (not (= (:type token) :fill))
    \\               @(:done-nl (:logical-block token))))
    \\    (emit-nl pw token)
    \\    (when-let [tws (getf pw :trailing-white-space)]
    \\      (pw-base-write pw tws)))
    \\  (setf pw :trailing-white-space nil))
    \\
    \\(defn- write-tokens [pw tokens force-trailing-whitespace]
    \\  (doseq [token tokens]
    \\    (when-not (= (:type-tag token) :nl-t)
    \\      (when-let [tws (getf pw :trailing-white-space)]
    \\        (pw-base-write pw tws)))
    \\    (write-token pw token)
    \\    (setf pw :trailing-white-space (:trailing-white-space token)))
    \\  (let [tws (getf pw :trailing-white-space)]
    \\    (when (and force-trailing-whitespace tws)
    \\      (pw-base-write pw tws)
    \\      (setf pw :trailing-white-space nil))))
    \\
    \\(defn- tokens-fit? [pw tokens]
    \\  (let [maxcol (get-max-column (getf pw :base))]
    \\    (or (nil? maxcol)
    \\        (< (+ (get-column (getf pw :base)) (buffer-length tokens)) maxcol))))
    \\
    \\(defn- linear-nl? [pw lb section]
    \\  (or @(:done-nl lb)
    \\      (not (tokens-fit? pw section))))
    \\
    \\(defn- miser-nl? [pw lb section]
    \\  (let [miser-width (get-miser-width pw)
    \\        maxcol (get-max-column (getf pw :base))]
    \\    (and miser-width maxcol
    \\         (>= @(:start-col lb) (- maxcol miser-width))
    \\         (linear-nl? pw lb section))))
    \\
    \\(defmulti ^{:private true} emit-nl? (fn [t _ _ _] (:type t)))
    \\
    \\(defmethod emit-nl? :linear [newl pw section _]
    \\  (linear-nl? pw (:logical-block newl) section))
    \\
    \\(defmethod emit-nl? :miser [newl pw section _]
    \\  (miser-nl? pw (:logical-block newl) section))
    \\
    \\(defmethod emit-nl? :fill [newl pw section subsection]
    \\  (let [lb (:logical-block newl)]
    \\    (or @(:intra-block-nl lb)
    \\        (not (tokens-fit? pw subsection))
    \\        (miser-nl? pw lb section))))
    \\
    \\(defmethod emit-nl? :mandatory [_ _ _ _]
    \\  true)
    \\
    \\(defn- get-section [buffer]
    \\  (let [nl (first buffer)
    \\        lb (:logical-block nl)
    \\        section (seq (take-while #(not (and (nl-t? %) (ancestor? (:logical-block %) lb)))
    \\                                 (next buffer)))]
    \\    [section (seq (drop (inc (count section)) buffer))]))
    \\
    \\(defn- get-sub-section [buffer]
    \\  (let [nl (first buffer)
    \\        lb (:logical-block nl)
    \\        section (seq (take-while #(let [nl-lb (:logical-block %)]
    \\                                    (not (and (nl-t? %)
    \\                                              (or (= nl-lb lb)
    \\                                                  (ancestor? nl-lb lb)))))
    \\                                 (next buffer)))]
    \\    section))
    \\
    \\(defn- update-nl-state [lb]
    \\  (reset! (:intra-block-nl lb) false)
    \\  (reset! (:done-nl lb) true)
    \\  (loop [lb (:parent lb)]
    \\    (when lb
    \\      (reset! (:done-nl lb) true)
    \\      (reset! (:intra-block-nl lb) true)
    \\      (recur (:parent lb)))))
    \\
    \\(defn- emit-nl [pw nl]
    \\  (pw-base-write pw (pp-newline))
    \\  (setf pw :trailing-white-space nil)
    \\  (let [lb (:logical-block nl)
    \\        prefix (:per-line-prefix lb)]
    \\    (when prefix
    \\      (pw-base-write pw prefix))
    \\    (let [istr (apply str (repeat (- @(:indent lb) (count (or prefix ""))) \space))]
    \\      (pw-base-write pw istr))
    \\    (update-nl-state lb)))
    \\
    \\(defn- split-at-newline [tokens]
    \\  (let [pre (seq (take-while #(not (nl-t? %)) tokens))]
    \\    [pre (seq (drop (count pre) tokens))]))
    \\
    \\;; Write-token-string: called when buffer doesn't fit on line
    \\(defn- write-token-string [pw tokens]
    \\  (let [[a b] (split-at-newline tokens)]
    \\    (when a (write-tokens pw a false))
    \\    (when b
    \\      (let [[section remainder] (get-section b)
    \\            newl (first b)
    \\            do-nl (emit-nl? newl pw section (get-sub-section b))
    \\            result (if do-nl
    \\                     (do (emit-nl pw newl) (next b))
    \\                     b)
    \\            long-section (not (tokens-fit? pw result))
    \\            result (if long-section
    \\                     (let [rem2 (write-token-string pw section)]
    \\                       (if (= rem2 section)
    \\                         (do (write-tokens pw section false) remainder)
    \\                         (into [] (concat rem2 remainder))))
    \\                     result)]
    \\        result))))
    \\
    \\(defn- write-line [pw]
    \\  (loop [buffer (getf pw :buffer)]
    \\    (setf pw :buffer (into [] buffer))
    \\    (when-not (tokens-fit? pw buffer)
    \\      (let [new-buffer (write-token-string pw buffer)]
    \\        (when-not (identical? buffer new-buffer)
    \\          (recur new-buffer))))))
    \\
    \\(defn- add-to-buffer [pw token]
    \\  (setf pw :buffer (conj (getf pw :buffer) token))
    \\  (when-not (tokens-fit? pw (getf pw :buffer))
    \\    (write-line pw)))
    \\
    \\(defn- write-buffered-output [pw]
    \\  (write-line pw)
    \\  (when-let [buf (getf pw :buffer)]
    \\    (when (seq buf)
    \\      (write-tokens pw buf true)
    \\      (setf pw :buffer []))))
    \\
    \\(defn- write-white-space [pw]
    \\  (when-let [tws (getf pw :trailing-white-space)]
    \\    (pw-base-write pw tws)
    \\    (setf pw :trailing-white-space nil)))
    \\
    \\(defn- index-of-from [s sub start]
    \\  (let [idx (.indexOf (subs s start) sub)]
    \\    (if (neg? idx) -1 (+ idx start))))
    \\
    \\(defn- split-string-newline [s]
    \\  (loop [result [] start 0]
    \\    (let [idx (index-of-from s "\n" start)]
    \\      (if (neg? idx)
    \\        (conj result (subs s start))
    \\        (recur (conj result (subs s start idx)) (inc idx))))))
    \\
    \\(defn- write-initial-lines [pw s]
    \\  (let [lines (split-string-newline s)]
    \\    (if (= (count lines) 1)
    \\      s
    \\      (let [prefix (:per-line-prefix (getf pw :logical-blocks))
    \\            l (first lines)]
    \\        (if (= :buffering (getf pw :mode))
    \\          (let [oldpos (getf pw :pos)
    \\                newpos (+ oldpos (count l))]
    \\            (setf pw :pos newpos)
    \\            (add-to-buffer pw (make-buffer-blob l nil oldpos newpos))
    \\            (write-buffered-output pw))
    \\          (do
    \\            (write-white-space pw)
    \\            (pw-base-write pw l)))
    \\        (pw-base-write-char pw \newline)
    \\        (doseq [l (next (butlast lines))]
    \\          (pw-base-write pw l)
    \\          (pw-base-write pw (pp-newline))
    \\          (when prefix
    \\            (pw-base-write pw prefix)))
    \\        (setf pw :mode :writing)
    \\        (last lines)))))
    \\
    \\(defn- p-write-char [pw c]
    \\  (if (= (getf pw :mode) :writing)
    \\    (do
    \\      (write-white-space pw)
    \\      (pw-base-write-char pw c))
    \\    (if (= c \newline)
    \\      (write-initial-lines pw "\n")
    \\      (let [oldpos (getf pw :pos)
    \\            newpos (inc oldpos)]
    \\        (setf pw :pos newpos)
    \\        (add-to-buffer pw (make-buffer-blob (str c) nil oldpos newpos))))))
    \\
    \\;; Create a pretty-writer
    \\(defn- pretty-writer [writer max-columns miser-width]
    \\  (let [lb (make-logical-block nil nil 0 0 false false nil nil nil)]
    \\    (atom {:pretty-writer true
    \\           :base (column-writer writer max-columns)
    \\           :logical-blocks lb
    \\           :sections nil
    \\           :mode :writing
    \\           :buffer []
    \\           :buffer-block lb
    \\           :buffer-level 1
    \\           :miser-width miser-width
    \\           :trailing-white-space nil
    \\           :pos 0})))
    \\
    \\;; Pretty-writer methods
    \\(defn- pw-write [pw s]
    \\  (let [s0 (write-initial-lines pw s)
    \\        ;; Trim trailing whitespace from s0
    \\        s-trimmed (rtrim-whitespace s0)
    \\        white-space (subs s0 (count s-trimmed))
    \\        mode (getf pw :mode)]
    \\    (if (= mode :writing)
    \\      (do
    \\        (write-white-space pw)
    \\        (pw-base-write pw s-trimmed)
    \\        (setf pw :trailing-white-space white-space))
    \\      (let [oldpos (getf pw :pos)
    \\            newpos (+ oldpos (count s0))]
    \\        (setf pw :pos newpos)
    \\        (add-to-buffer pw (make-buffer-blob s-trimmed white-space oldpos newpos))))))
    \\
    \\(defn- pw-ppflush [pw]
    \\  (if (= (getf pw :mode) :buffering)
    \\    (do
    \\      (write-tokens pw (getf pw :buffer) true)
    \\      (setf pw :buffer []))
    \\    (write-white-space pw)))
    \\
    \\(defn- start-block [pw prefix per-line-prefix suffix]
    \\  (let [lb (make-logical-block (getf pw :logical-blocks) nil 0 0 false false
    \\                               prefix per-line-prefix suffix)]
    \\    (setf pw :logical-blocks lb)
    \\    (if (= (getf pw :mode) :writing)
    \\      (do
    \\        (write-white-space pw)
    \\        (when-let [cb (getf pw :logical-block-callback)] (cb :start))
    \\        (when prefix (pw-base-write pw prefix))
    \\        (let [col (get-column (getf pw :base))]
    \\          (reset! (:start-col lb) col)
    \\          (reset! (:indent lb) col)))
    \\      (let [oldpos (getf pw :pos)
    \\            newpos (+ oldpos (if prefix (count prefix) 0))]
    \\        (setf pw :pos newpos)
    \\        (add-to-buffer pw (make-start-block-t lb oldpos newpos))))))
    \\
    \\(defn- end-block [pw]
    \\  (let [lb (getf pw :logical-blocks)
    \\        suffix (:suffix lb)]
    \\    (if (= (getf pw :mode) :writing)
    \\      (do
    \\        (write-white-space pw)
    \\        (when suffix (pw-base-write pw suffix))
    \\        (when-let [cb (getf pw :logical-block-callback)] (cb :end)))
    \\      (let [oldpos (getf pw :pos)
    \\            newpos (+ oldpos (if suffix (count suffix) 0))]
    \\        (setf pw :pos newpos)
    \\        (add-to-buffer pw (make-end-block-t lb oldpos newpos))))
    \\    (setf pw :logical-blocks (:parent lb))))
    \\
    \\(defn- nl [pw type]
    \\  (setf pw :mode :buffering)
    \\  (let [pos (getf pw :pos)]
    \\    (add-to-buffer pw (make-nl-t type (getf pw :logical-blocks) pos pos))))
    \\
    \\(defn- indent [pw relative-to offset]
    \\  (let [lb (getf pw :logical-blocks)]
    \\    (if (= (getf pw :mode) :writing)
    \\      (do
    \\        (write-white-space pw)
    \\        (reset! (:indent lb)
    \\                (+ offset (condp = relative-to
    \\                            :block @(:start-col lb)
    \\                            :current (get-column (getf pw :base))))))
    \\      (let [pos (getf pw :pos)]
    \\        (add-to-buffer pw (make-indent-t lb relative-to offset pos pos))))))
    \\
    \\(defn- get-miser-width [pw]
    \\  (getf pw :miser-width))
    \\
    \\;; Public API — cw-write for dispatch functions
    \\
    \\(defn- cw-write
    \\  "Write a string through the active pretty-writer, or directly to stdout."
    \\  [s]
    \\  (if *pw*
    \\    (pw-write *pw* (str s))
    \\    (print s)))
    \\
    \\(defn- cw-write-char-out
    \\  "Write a single character through the active pretty-writer."
    \\  [c]
    \\  (if *pw*
    \\    (p-write-char *pw* c)
    \\    (print (str c))))
    \\
    \\;; pprint_base — public API functions
    \\
    \\(defn- check-enumerated-arg [arg choices]
    \\  (when-not (choices arg)
    \\    (throw (ex-info (str "Bad argument: " arg ". Expected one of " choices)
    \\                    {:arg arg :choices choices}))))
    \\
    \\;; Internal tracking vars (match upstream)
    \\(def ^:dynamic ^{:private true} *current-level* 0)
    \\(def ^:dynamic ^{:private true} *current-length* nil)
    \\
    \\(defn- pretty-writer? [x]
    \\  (and (instance? clojure.lang.Atom x) (:pretty-writer @x)))
    \\
    \\(defn- make-pretty-writer [base-writer right-margin miser-width]
    \\  (pretty-writer base-writer right-margin miser-width))
    \\
    \\(defn get-pretty-writer
    \\  "Returns the pretty writer wrapped around the base writer."
    \\  {:added "1.2"}
    \\  [base-writer]
    \\  (if (pretty-writer? base-writer)
    \\    base-writer
    \\    (make-pretty-writer base-writer *print-right-margin* *print-miser-width*)))
    \\
    \\(defn fresh-line
    \\  "If the output is not already at the beginning of a line, output a newline."
    \\  {:added "1.2"}
    \\  []
    \\  (if *pw*
    \\    (when (not (zero? (get-column (getf *pw* :base))))
    \\      (cw-write "\n"))
    \\    (println)))
    \\
    \\(declare format-simple-number)
    \\
    \\(defn- int-to-base-string [n base]
    \\  (if (zero? n) "0"
    \\      (let [neg? (neg? n)
    \\            n (if neg? (- n) n)
    \\            digits "0123456789abcdefghijklmnopqrstuvwxyz"]
    \\        (loop [n n acc ""]
    \\          (if (zero? n)
    \\            (if neg? (str "-" acc) acc)
    \\            (recur (quot n base)
    \\                   (str (nth digits (rem n base)) acc)))))))
    \\
    \\(defn- format-simple-number [x]
    \\  (cond
    \\    (integer? x)
    \\    (if (or (not (= *print-base* 10)) *print-radix*)
    \\      (let [base *print-base*
    \\            prefix (cond (= base 2) "#b"
    \\                         (= base 8) "#o"
    \\                         (= base 16) "#x"
    \\                         *print-radix* (str "#" base "r")
    \\                         :else "")]
    \\        ;; UPSTREAM-DIFF: pure Clojure base formatting (no Integer/toString)
    \\        (str prefix (int-to-base-string x base)))
    \\      nil)
    \\    :else nil))
    \\
    \\(def ^{:private true} write-option-table
    \\  {:base 'clojure.pprint/*print-base*
    \\   :circle nil  ;; not yet supported
    \\   :length 'clojure.core/*print-length*
    \\   :level 'clojure.core/*print-level*
    \\   :lines nil   ;; not yet supported
    \\   :miser-width 'clojure.pprint/*print-miser-width*
    \\   :dispatch 'clojure.pprint/*print-pprint-dispatch*
    \\   :pretty 'clojure.pprint/*print-pretty*
    \\   :radix 'clojure.pprint/*print-radix*
    \\   :readably 'clojure.core/*print-readably*
    \\   :right-margin 'clojure.pprint/*print-right-margin*
    \\   :suppress-namespaces 'clojure.pprint/*print-suppress-namespaces*})
    \\
    \\(defn- table-ize [t m]
    \\  (apply hash-map (mapcat
    \\                   #(when-let [v (get t (key %))]
    \\                      (when-let [var (find-var v)]
    \\                        [var (val %)]))
    \\                   m)))
    \\
    \\(defmacro ^{:private true} binding-map [amap & body]
    \\  `(do
    \\     (push-thread-bindings ~amap)
    \\     (try
    \\       ~@body
    \\       (finally
    \\         (pop-thread-bindings)))))
    \\
    \\(defn write-out
    \\  "Write an object to *out* subject to the current bindings of the printer control
    \\variables."
    \\  {:added "1.2"}
    \\  [object]
    \\  (let [length-reached (and
    \\                        *current-length*
    \\                        *print-length*
    \\                        (>= *current-length* *print-length*))]
    \\    (if-not *print-pretty*
    \\      (pr object)
    \\      (if length-reached
    \\        (cw-write "...")
    \\        (do
    \\          (when *current-length* (set! *current-length* (inc *current-length*)))
    \\          (*print-pprint-dispatch* object))))
    \\    length-reached))
    \\
    \\(defn write
    \\  "Write an object subject to the current bindings of the printer control variables.
    \\Use the kw-args argument to override individual variables for this call (and any
    \\recursive calls). Returns the string result if :stream is nil or nil otherwise."
    \\  {:added "1.2"}
    \\  [object & kw-args]
    \\  (let [options (merge {:stream true} (apply hash-map kw-args))]
    \\    (binding-map (table-ize write-option-table options)
    \\                 (let [optval (if (contains? options :stream) (:stream options) true)
    \\                       sb (when (nil? optval) (StringBuilder.))]
    \\        ;; UPSTREAM-DIFF: CW uses *pw* binding instead of rebinding *out* to a Writer
    \\                   (if *print-pretty*
    \\                     (let [pw (make-pretty-writer nil *print-right-margin* *print-miser-width*)]
    \\                       (binding [*pw* pw]
    \\                         (write-out object))
    \\                       (pw-ppflush pw))
    \\                     (pr object))
    \\        ;; TODO: when :stream is nil, capture and return string
    \\                   (when (nil? optval)
    \\                     nil)))))
    \\
    \\;; UPSTREAM-DIFF: Override Zig builtin pprint with Clojure implementation
    \\;; that dispatches through *print-pprint-dispatch* (enables code-dispatch etc.)
    \\(defn pprint
    \\  "Pretty print object to the optional output writer. If the writer is not provided,
    \\print the object to the currently bound value of *out*."
    \\  {:added "1.2"}
    \\  ([object] (pprint object *out*))
    \\  ([object writer]
    \\   (let [pw (make-pretty-writer writer *print-right-margin* *print-miser-width*)]
    \\     (binding [*print-pretty* true
    \\               *pw* pw]
    \\       (write-out object))
    \\     (pw-ppflush pw)
    \\     ;; Add trailing newline
    \\     (println))
    \\   nil))
    \\
    \\(defn- level-exceeded []
    \\  (and *print-level* (>= *current-level* *print-level*)))
    \\
    \\(defn- parse-lb-options [opts body]
    \\  (loop [body body acc []]
    \\    (if (opts (first body))
    \\      (recur (drop 2 body) (concat acc (take 2 body)))
    \\      [(apply hash-map acc) body])))
    \\
    \\(defmacro pprint-logical-block
    \\  "Execute the body as a pretty printing logical block with output to *out* which
    \\must be a pretty printing writer."
    \\  {:added "1.2" :arglists '[[options* body]]}
    \\  [& args]
    \\  (let [[options body] (parse-lb-options #{:prefix :per-line-prefix :suffix} args)]
    \\    `(do (if (level-exceeded)
    \\           (cw-write "#")
    \\           (do
    \\             (push-thread-bindings {#'*current-level*
    \\                                    (inc *current-level*)
    \\                                    #'*current-length* 0})
    \\             (try
    \\               (when *pw*
    \\                 (start-block *pw* ~(:prefix options) ~(:per-line-prefix options) ~(:suffix options)))
    \\               (when-not *pw*
    \\                 (when ~(:prefix options) (cw-write ~(:prefix options))))
    \\               ~@body
    \\               (when *pw*
    \\                 (end-block *pw*))
    \\               (when-not *pw*
    \\                 (when ~(:suffix options) (cw-write ~(:suffix options))))
    \\               (finally
    \\                 (pop-thread-bindings)))))
    \\         nil)))
    \\
    \\(defn pprint-newline
    \\  "Print a conditional newline to a pretty printing stream."
    \\  {:added "1.2"}
    \\  [kind]
    \\  (check-enumerated-arg kind #{:linear :miser :fill :mandatory})
    \\  (if *pw*
    \\    (nl *pw* kind)
    \\    (when (= kind :mandatory) (println))))
    \\
    \\(defn pprint-indent
    \\  "Create an indent at this point in the pretty printing stream."
    \\  {:added "1.2"}
    \\  [relative-to n]
    \\  (check-enumerated-arg relative-to #{:block :current})
    \\  (when *pw*
    \\    (indent *pw* relative-to n)))
    \\
    \\(defn pprint-tab
    \\  "Tab at this point in the pretty printing stream.
    \\THIS FUNCTION IS NOT YET IMPLEMENTED."
    \\  {:added "1.2"}
    \\  [kind colnum colinc]
    \\  (check-enumerated-arg kind #{:line :section :line-relative :section-relative})
    \\  (throw (ex-info "pprint-tab is not yet implemented" {:kind kind})))
    \\
    \\;; Helper for dispatch functions
    \\(defn- pll-mod-body [var-sym body]
    \\  (letfn [(inner [form]
    \\            (if (seq? form)
    \\              (let [form (macroexpand form)]
    \\                (condp = (first form)
    \\                  'loop* form
    \\                  'recur (concat `(recur (inc ~var-sym)) (rest form))
    \\                  (clojure.walk/walk inner identity form)))
    \\              form))]
    \\    (clojure.walk/walk inner identity body)))
    \\
    \\(defmacro print-length-loop
    \\  "A version of loop that iterates at most *print-length* times."
    \\  {:added "1.3"}
    \\  [bindings & body]
    \\  (let [count-var (gensym "length-count")
    \\        mod-body (pll-mod-body count-var body)]
    \\    `(loop ~(apply vector count-var 0 bindings)
    \\       (if (or (not *print-length*) (< ~count-var *print-length*))
    \\         (do ~@mod-body)
    \\         (cw-write "...")))))
    \\
    \\;; simple-dispatch — pretty print dispatch for data
    \\;; UPSTREAM-DIFF: uses CW type predicates instead of Java class dispatch
    \\
    \\(declare pprint-map)
    \\
    \\(defn- pprint-simple-list [alis]
    \\  (pprint-logical-block :prefix "(" :suffix ")"
    \\                        (print-length-loop [alis (seq alis)]
    \\                                           (when alis
    \\                                             (write-out (first alis))
    \\                                             (when (next alis)
    \\                                               (cw-write " ")
    \\                                               (pprint-newline :linear)
    \\                                               (recur (next alis)))))))
    \\
    \\(defn- pprint-list [alis]
    \\  ;; UPSTREAM-DIFF: simple-dispatch prints lists literally (no reader macro expansion).
    \\  ;; Reader macro expansion is only in code-dispatch's pprint-code-list.
    \\  (pprint-simple-list alis))
    \\
    \\(defn- pprint-vector [avec]
    \\  (pprint-logical-block :prefix "[" :suffix "]"
    \\                        (print-length-loop [aseq (seq avec)]
    \\                                           (when aseq
    \\                                             (write-out (first aseq))
    \\                                             (when (next aseq)
    \\                                               (cw-write " ")
    \\                                               (pprint-newline :linear)
    \\                                               (recur (next aseq)))))))
    \\
    \\(defn- pprint-map [amap]
    \\  ;; UPSTREAM-DIFF: skip lift-ns (CW doesn't have namespace map lifting)
    \\  (let [prefix "{"]
    \\    (pprint-logical-block :prefix prefix :suffix "}"
    \\                          (print-length-loop [aseq (seq amap)]
    \\                                             (when aseq
    \\                                               (pprint-logical-block
    \\                                                (write-out (ffirst aseq))
    \\                                                (cw-write " ")
    \\                                                (pprint-newline :linear)
    \\                                                (set! *current-length* 0)
    \\                                                (write-out (fnext (first aseq))))
    \\                                               (when (next aseq)
    \\                                                 (cw-write ", ")
    \\                                                 (pprint-newline :linear)
    \\                                                 (recur (next aseq))))))))
    \\
    \\(defn- pprint-set [aset]
    \\  (pprint-logical-block :prefix "#{" :suffix "}"
    \\                        (print-length-loop [aseq (seq aset)]
    \\                                           (when aseq
    \\                                             (write-out (first aseq))
    \\                                             (when (next aseq)
    \\                                               (cw-write " ")
    \\                                               (pprint-newline :linear)
    \\                                               (recur (next aseq)))))))
    \\
    \\(defn- pprint-simple-default [obj]
    \\  (cond
    \\    (and *print-suppress-namespaces* (symbol? obj)) (cw-write (name obj))
    \\    :else (cw-write (pr-str obj))))
    \\
    \\(defn simple-dispatch
    \\  "The pretty print dispatch function for simple data structure format."
    \\  {:added "1.2"}
    \\  [object]
    \\  (cond
    \\    (nil? object) (cw-write (pr-str nil))
    \\    (seq? object) (pprint-list object)
    \\    (vector? object) (pprint-vector object)
    \\    (map? object) (pprint-map object)
    \\    (set? object) (pprint-set object)
    \\    (symbol? object) (pprint-simple-default object)
    \\    :else (pprint-simple-default object)))
    \\
    \\(defn set-pprint-dispatch
    \\  "Set the pretty print dispatch function to a function matching (fn [obj] ...)."
    \\  {:added "1.2"}
    \\  [function]
    \\  (let [old-meta (meta #'*print-pprint-dispatch*)]
    \\    (alter-var-root #'*print-pprint-dispatch* (constantly function))
    \\    (alter-meta! #'*print-pprint-dispatch* (constantly old-meta)))
    \\  nil)
    \\
    \\;; Set simple-dispatch as the default
    \\(set-pprint-dispatch simple-dispatch)
    \\
    \\;; Convenience macros
    \\
    \\(defmacro pp
    \\  "A convenience macro that pretty prints the last thing output. This is
    \\exactly equivalent to (pprint *1)."
    \\  {:added "1.2"}
    \\  [] `(pprint *1))
    \\
    \\(defmacro with-pprint-dispatch
    \\  "Execute body with the pretty print dispatch function bound to function."
    \\  {:added "1.2"}
    \\  [function & body]
    \\  `(binding [*print-pprint-dispatch* ~function]
    \\     ~@body))
    \\
    \\;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    \\;;; cl-format — Common Lisp compatible format
    \\;;; UPSTREAM-DIFF: CW port of cl_format.clj + utilities.clj
    \\;;; Adaptations: RuntimeException→ex-info, Writer proxy→with-out-str,
    \\;;;   .length→count, .numerator/.denominator→functions,
    \\;;;   java.io.StringWriter→with-out-str, Math/abs→conditional negate,
    \\;;;   format "%o"/"%x"→pure Clojure base conversion
    \\;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    \\
    \\;;; Forward references
    \\(declare compile-format)
    \\(declare execute-format)
    \\(declare init-navigator)
    \\
    \\;; UPSTREAM-DIFF: Character/toUpperCase and Character/toLowerCase not available in CW
    \\;; Use string method via (first (.toUpperCase (str c))) pattern
    \\(defn- char-upper [c] (first (.toUpperCase (str c))))
    \\(defn- char-lower [c] (first (.toLowerCase (str c))))
    \\
    \\;;; Utility functions (from utilities.clj)
    \\
    \\(defn- map-passing-context [func initial-context lis]
    \\  (loop [context initial-context
    \\         lis lis
    \\         acc []]
    \\    (if (empty? lis)
    \\      [acc context]
    \\      (let [this (first lis)
    \\            remainder (next lis)
    \\            [result new-context] (apply func [this context])]
    \\        (recur new-context remainder (conj acc result))))))
    \\
    \\(defn- consume [func initial-context]
    \\  (loop [context initial-context
    \\         acc []]
    \\    (let [[result new-context] (apply func [context])]
    \\      (if (not result)
    \\        [acc new-context]
    \\        (recur new-context (conj acc result))))))
    \\
    \\(defn- unzip-map [m]
    \\  [(into {} (for [[k [v1 v2]] m] [k v1]))
    \\   (into {} (for [[k [v1 v2]] m] [k v2]))])
    \\
    \\(defn- tuple-map [m v1]
    \\  (into {} (for [[k v] m] [k [v v1]])))
    \\
    \\(defn- rtrim [s c]
    \\  (let [len (count s)]
    \\    (if (and (pos? len) (= (nth s (dec len)) c))
    \\      (loop [n (dec len)]
    \\        (cond
    \\          (neg? n) ""
    \\          (not (= (nth s n) c)) (subs s 0 (inc n))
    \\          true (recur (dec n))))
    \\      s)))
    \\
    \\(defn- ltrim [s c]
    \\  (let [len (count s)]
    \\    (if (and (pos? len) (= (nth s 0) c))
    \\      (loop [n 0]
    \\        (if (or (= n len) (not (= (nth s n) c)))
    \\          (subs s n)
    \\          (recur (inc n))))
    \\      s)))
    \\
    \\(defn- prefix-count [aseq val]
    \\  (let [test (if (coll? val) (set val) #{val})]
    \\    (loop [pos 0]
    \\      (if (or (= pos (count aseq)) (not (test (nth aseq pos))))
    \\        pos
    \\        (recur (inc pos))))))
    \\
    \\;;; cl-format
    \\
    \\(def ^:dynamic ^{:private true} *format-str* nil)
    \\
    \\(defn- format-error [message offset]
    \\  (let [full-message (str message \newline *format-str* \newline
    \\                          (apply str (repeat offset \space)) "^" \newline)]
    \\    (throw (ex-info full-message {:type :format-error :offset offset}))))
    \\
    \\;;; Argument navigators
    \\
    \\(defstruct ^{:private true}
    \\ arg-navigator :seq :rest :pos)
    \\
    \\(defn- init-navigator [s]
    \\  (let [s (seq s)]
    \\    (struct arg-navigator s s 0)))
    \\
    \\(defn- next-arg [navigator]
    \\  (let [rst (:rest navigator)]
    \\    (if rst
    \\      [(first rst) (struct arg-navigator (:seq navigator) (next rst) (inc (:pos navigator)))]
    \\      (throw (ex-info "Not enough arguments for format definition" {:type :format-error})))))
    \\
    \\(defn- next-arg-or-nil [navigator]
    \\  (let [rst (:rest navigator)]
    \\    (if rst
    \\      [(first rst) (struct arg-navigator (:seq navigator) (next rst) (inc (:pos navigator)))]
    \\      [nil navigator])))
    \\
    \\(defn- get-format-arg [navigator]
    \\  (let [[raw-format navigator] (next-arg navigator)
    \\        compiled-format (if (string? raw-format)
    \\                          (compile-format raw-format)
    \\                          raw-format)]
    \\    [compiled-format navigator]))
    \\
    \\(declare relative-reposition)
    \\
    \\(defn- absolute-reposition [navigator position]
    \\  (if (>= position (:pos navigator))
    \\    (relative-reposition navigator (- position (:pos navigator)))
    \\    (struct arg-navigator (:seq navigator) (drop position (:seq navigator)) position)))
    \\
    \\(defn- relative-reposition [navigator position]
    \\  (let [newpos (+ (:pos navigator) position)]
    \\    (if (neg? position)
    \\      (absolute-reposition navigator newpos)
    \\      (struct arg-navigator (:seq navigator) (drop position (:rest navigator)) newpos))))
    \\
    \\(defstruct ^{:private true}
    \\ compiled-directive :func :def :params :offset)
    \\
    \\;;; Parameter realization
    \\
    \\(defn- realize-parameter [[param [raw-val offset]] navigator]
    \\  (let [[real-param new-navigator]
    \\        (cond
    \\          (contains? #{:at :colon} param)
    \\          [raw-val navigator]
    \\
    \\          (= raw-val :parameter-from-args)
    \\          (next-arg navigator)
    \\
    \\          (= raw-val :remaining-arg-count)
    \\          [(count (:rest navigator)) navigator]
    \\
    \\          true
    \\          [raw-val navigator])]
    \\    [[param [real-param offset]] new-navigator]))
    \\
    \\(defn- realize-parameter-list [parameter-map navigator]
    \\  (let [[pairs new-navigator]
    \\        (map-passing-context realize-parameter navigator parameter-map)]
    \\    [(into {} pairs) new-navigator]))
    \\
    \\;;; Directive support functions
    \\
    \\(declare opt-base-str)
    \\
    \\(def ^{:private true}
    \\  special-radix-markers {2 "#b" 8 "#o" 16 "#x"})
    \\
    \\;; UPSTREAM-DIFF: uses numerator/denominator functions instead of .numerator/.denominator methods
    \\(defn- format-simple-number-for-cl [n]
    \\  (cond
    \\    (integer? n) (if (= *print-base* 10)
    \\                   (str n (if *print-radix* "."))
    \\                   (str
    \\                    (if *print-radix* (or (get special-radix-markers *print-base*) (str "#" *print-base* "r")))
    \\                    (opt-base-str *print-base* n)))
    \\    (ratio? n) (str
    \\                (if *print-radix* (or (get special-radix-markers *print-base*) (str "#" *print-base* "r")))
    \\                (opt-base-str *print-base* (numerator n))
    \\                "/"
    \\                (opt-base-str *print-base* (denominator n)))
    \\    :else nil))
    \\
    \\(defn- format-ascii [print-func params arg-navigator offsets]
    \\  (let [[arg arg-navigator] (next-arg arg-navigator)
    \\        ;; UPSTREAM-DIFF: CW's print-str returns "" for nil, upstream returns "nil"
    \\        raw-output (or (format-simple-number-for-cl arg)
    \\                       (let [s (print-func arg)] (if (and (nil? arg) (= s "")) "nil" s)))
    \\        base-output (str raw-output)
    \\        base-width (count base-output)
    \\        min-width (+ base-width (:minpad params))
    \\        width (if (>= min-width (:mincol params))
    \\                min-width
    \\                (+ min-width
    \\                   (* (+ (quot (- (:mincol params) min-width 1)
    \\                               (:colinc params))
    \\                         1)
    \\                      (:colinc params))))
    \\        chars (apply str (repeat (- width base-width) (:padchar params)))]
    \\    (if (:at params)
    \\      (print (str chars base-output))
    \\      (print (str base-output chars)))
    \\    arg-navigator))
    \\
    \\;;; Integer directives
    \\
    \\(defn- integral? [x]
    \\  (cond
    \\    (integer? x) true
    \\    (float? x) (== x (Math/floor x))
    \\    (ratio? x) (= 0 (rem (numerator x) (denominator x)))
    \\    :else false))
    \\
    \\(defn- remainders [base val]
    \\  (reverse
    \\   (first
    \\    (consume #(if (pos? %)
    \\                [(rem % base) (quot % base)]
    \\                [nil nil])
    \\             val))))
    \\
    \\(defn- base-str [base val]
    \\  (if (zero? val)
    \\    "0"
    \\    (apply str
    \\           (map
    \\            #(if (< % 10) (char (+ (int \0) %)) (char (+ (int \a) (- % 10))))
    \\            (remainders base val)))))
    \\
    \\;; UPSTREAM-DIFF: no Java format for %o/%x, always use base-str
    \\(defn- opt-base-str [base val]
    \\  (base-str base val))
    \\
    \\(defn- group-by* [unit lis]
    \\  (reverse
    \\   (first
    \\    (consume (fn [x] [(seq (reverse (take unit x))) (seq (drop unit x))]) (reverse lis)))))
    \\
    \\(defn- format-integer [base params arg-navigator offsets]
    \\  (let [[arg arg-navigator] (next-arg arg-navigator)]
    \\    (if (integral? arg)
    \\      (let [neg (neg? arg)
    \\            pos-arg (if neg (- arg) arg)
    \\            raw-str (opt-base-str base pos-arg)
    \\            group-str (if (:colon params)
    \\                        (let [groups (map #(apply str %) (group-by* (:commainterval params) raw-str))
    \\                              commas (repeat (count groups) (:commachar params))]
    \\                          (apply str (next (interleave commas groups))))
    \\                        raw-str)
    \\            signed-str (cond
    \\                         neg (str "-" group-str)
    \\                         (:at params) (str "+" group-str)
    \\                         true group-str)
    \\            padded-str (if (< (count signed-str) (:mincol params))
    \\                         (str (apply str (repeat (- (:mincol params) (count signed-str))
    \\                                                 (:padchar params)))
    \\                              signed-str)
    \\                         signed-str)]
    \\        (print padded-str))
    \\      (format-ascii print-str {:mincol (:mincol params) :colinc 1 :minpad 0
    \\                               :padchar (:padchar params) :at true}
    \\                    (init-navigator [arg]) nil))
    \\    arg-navigator))
    \\
    \\;;; English number formats
    \\
    \\(def ^{:private true}
    \\  english-cardinal-units
    \\  ["zero" "one" "two" "three" "four" "five" "six" "seven" "eight" "nine"
    \\   "ten" "eleven" "twelve" "thirteen" "fourteen"
    \\   "fifteen" "sixteen" "seventeen" "eighteen" "nineteen"])
    \\
    \\(def ^{:private true}
    \\  english-ordinal-units
    \\  ["zeroth" "first" "second" "third" "fourth" "fifth" "sixth" "seventh" "eighth" "ninth"
    \\   "tenth" "eleventh" "twelfth" "thirteenth" "fourteenth"
    \\   "fifteenth" "sixteenth" "seventeenth" "eighteenth" "nineteenth"])
    \\
    \\(def ^{:private true}
    \\  english-cardinal-tens
    \\  ["" "" "twenty" "thirty" "forty" "fifty" "sixty" "seventy" "eighty" "ninety"])
    \\
    \\(def ^{:private true}
    \\  english-ordinal-tens
    \\  ["" "" "twentieth" "thirtieth" "fortieth" "fiftieth"
    \\   "sixtieth" "seventieth" "eightieth" "ninetieth"])
    \\
    \\(def ^{:private true}
    \\  english-scale-numbers
    \\  ["" "thousand" "million" "billion" "trillion" "quadrillion" "quintillion"
    \\   "sextillion" "septillion" "octillion" "nonillion" "decillion"
    \\   "undecillion" "duodecillion" "tredecillion" "quattuordecillion"
    \\   "quindecillion" "sexdecillion" "septendecillion"
    \\   "octodecillion" "novemdecillion" "vigintillion"])
    \\
    \\(defn- format-simple-cardinal [num]
    \\  (let [hundreds (quot num 100)
    \\        tens (rem num 100)]
    \\    (str
    \\     (if (pos? hundreds) (str (nth english-cardinal-units hundreds) " hundred"))
    \\     (if (and (pos? hundreds) (pos? tens)) " ")
    \\     (if (pos? tens)
    \\       (if (< tens 20)
    \\         (nth english-cardinal-units tens)
    \\         (let [ten-digit (quot tens 10)
    \\               unit-digit (rem tens 10)]
    \\           (str
    \\            (if (pos? ten-digit) (nth english-cardinal-tens ten-digit))
    \\            (if (and (pos? ten-digit) (pos? unit-digit)) "-")
    \\            (if (pos? unit-digit) (nth english-cardinal-units unit-digit)))))))))
    \\
    \\(defn- add-english-scales [parts offset]
    \\  (let [cnt (count parts)]
    \\    (loop [acc []
    \\           pos (dec cnt)
    \\           this (first parts)
    \\           remainder (next parts)]
    \\      (if (nil? remainder)
    \\        (str (apply str (interpose ", " acc))
    \\             (if (and (not (empty? this)) (not (empty? acc))) ", ")
    \\             this
    \\             (if (and (not (empty? this)) (pos? (+ pos offset)))
    \\               (str " " (nth english-scale-numbers (+ pos offset)))))
    \\        (recur
    \\         (if (empty? this)
    \\           acc
    \\           (conj acc (str this " " (nth english-scale-numbers (+ pos offset)))))
    \\         (dec pos)
    \\         (first remainder)
    \\         (next remainder))))))
    \\
    \\(defn- format-cardinal-english [params navigator offsets]
    \\  (let [[arg navigator] (next-arg navigator)]
    \\    (if (= 0 arg)
    \\      (print "zero")
    \\      (let [abs-arg (if (neg? arg) (- arg) arg)
    \\            parts (remainders 1000 abs-arg)]
    \\        (if (<= (count parts) (count english-scale-numbers))
    \\          (let [parts-strs (map format-simple-cardinal parts)
    \\                full-str (add-english-scales parts-strs 0)]
    \\            (print (str (if (neg? arg) "minus ") full-str)))
    \\          (format-integer
    \\           10
    \\           {:mincol 0 :padchar \space :commachar \, :commainterval 3 :colon true}
    \\           (init-navigator [arg])
    \\           {:mincol 0 :padchar 0 :commachar 0 :commainterval 0}))))
    \\    navigator))
    \\
    \\(defn- format-simple-ordinal [num]
    \\  (let [hundreds (quot num 100)
    \\        tens (rem num 100)]
    \\    (str
    \\     (if (pos? hundreds) (str (nth english-cardinal-units hundreds) " hundred"))
    \\     (if (and (pos? hundreds) (pos? tens)) " ")
    \\     (if (pos? tens)
    \\       (if (< tens 20)
    \\         (nth english-ordinal-units tens)
    \\         (let [ten-digit (quot tens 10)
    \\               unit-digit (rem tens 10)]
    \\           (if (and (pos? ten-digit) (not (pos? unit-digit)))
    \\             (nth english-ordinal-tens ten-digit)
    \\             (str
    \\              (if (pos? ten-digit) (nth english-cardinal-tens ten-digit))
    \\              (if (and (pos? ten-digit) (pos? unit-digit)) "-")
    \\              (if (pos? unit-digit) (nth english-ordinal-units unit-digit))))))
    \\       (if (pos? hundreds) "th")))))
    \\
    \\(defn- format-ordinal-english [params navigator offsets]
    \\  (let [[arg navigator] (next-arg navigator)]
    \\    (if (= 0 arg)
    \\      (print "zeroth")
    \\      (let [abs-arg (if (neg? arg) (- arg) arg)
    \\            parts (remainders 1000 abs-arg)]
    \\        (if (<= (count parts) (count english-scale-numbers))
    \\          (let [parts-strs (map format-simple-cardinal (drop-last parts))
    \\                head-str (add-english-scales parts-strs 1)
    \\                tail-str (format-simple-ordinal (last parts))]
    \\            (print (str (if (neg? arg) "minus ")
    \\                        (cond
    \\                          (and (not (empty? head-str)) (not (empty? tail-str)))
    \\                          (str head-str ", " tail-str)
    \\
    \\                          (not (empty? head-str)) (str head-str "th")
    \\                          :else tail-str))))
    \\          (do (format-integer
    \\               10
    \\               {:mincol 0 :padchar \space :commachar \, :commainterval 3 :colon true}
    \\               (init-navigator [arg])
    \\               {:mincol 0 :padchar 0 :commachar 0 :commainterval 0})
    \\              (let [low-two-digits (rem arg 100)
    \\                    not-teens (or (< 11 low-two-digits) (> 19 low-two-digits))
    \\                    low-digit (rem low-two-digits 10)]
    \\                (print (cond
    \\                         (and (== low-digit 1) not-teens) "st"
    \\                         (and (== low-digit 2) not-teens) "nd"
    \\                         (and (== low-digit 3) not-teens) "rd"
    \\                         :else "th")))))))
    \\    navigator))
    \\
    \\;;; Roman numeral formats
    \\
    \\(def ^{:private true}
    \\  old-roman-table
    \\  [["I" "II" "III" "IIII" "V" "VI" "VII" "VIII" "VIIII"]
    \\   ["X" "XX" "XXX" "XXXX" "L" "LX" "LXX" "LXXX" "LXXXX"]
    \\   ["C" "CC" "CCC" "CCCC" "D" "DC" "DCC" "DCCC" "DCCCC"]
    \\   ["M" "MM" "MMM"]])
    \\
    \\(def ^{:private true}
    \\  new-roman-table
    \\  [["I" "II" "III" "IV" "V" "VI" "VII" "VIII" "IX"]
    \\   ["X" "XX" "XXX" "XL" "L" "LX" "LXX" "LXXX" "XC"]
    \\   ["C" "CC" "CCC" "CD" "D" "DC" "DCC" "DCCC" "CM"]
    \\   ["M" "MM" "MMM"]])
    \\
    \\(defn- format-roman [table params navigator offsets]
    \\  (let [[arg navigator] (next-arg navigator)]
    \\    (if (and (number? arg) (> arg 0) (< arg 4000))
    \\      (let [digits (remainders 10 arg)]
    \\        (loop [acc []
    \\               pos (dec (count digits))
    \\               digits digits]
    \\          (if (empty? digits)
    \\            (print (apply str acc))
    \\            (let [digit (first digits)]
    \\              (recur (if (= 0 digit)
    \\                       acc
    \\                       (conj acc (nth (nth table pos) (dec digit))))
    \\                     (dec pos)
    \\                     (next digits))))))
    \\      (format-integer
    \\       10
    \\       {:mincol 0 :padchar \space :commachar \, :commainterval 3 :colon true}
    \\       (init-navigator [arg])
    \\       {:mincol 0 :padchar 0 :commachar 0 :commainterval 0}))
    \\    navigator))
    \\
    \\(defn- format-old-roman [params navigator offsets]
    \\  (format-roman old-roman-table params navigator offsets))
    \\
    \\(defn- format-new-roman [params navigator offsets]
    \\  (format-roman new-roman-table params navigator offsets))
    \\
    \\;;; Character formats
    \\
    \\(def ^{:private true}
    \\  special-chars {8 "Backspace" 9 "Tab" 10 "Newline" 13 "Return" 32 "Space"})
    \\
    \\(defn- pretty-character [params navigator offsets]
    \\  (let [[c navigator] (next-arg navigator)
    \\        as-int (int c)
    \\        base-char (bit-and as-int 127)
    \\        meta (bit-and as-int 128)
    \\        special (get special-chars base-char)]
    \\    (if (> meta 0) (print "Meta-"))
    \\    (print (cond
    \\             special special
    \\             (< base-char 32) (str "Control-" (char (+ base-char 64)))
    \\             (= base-char 127) "Control-?"
    \\             :else (char base-char)))
    \\    navigator))
    \\
    \\(defn- readable-character [params navigator offsets]
    \\  (let [[c navigator] (next-arg navigator)]
    \\    (condp = (:char-format params)
    \\      \o (cl-format true "\\o~3,'0o" (int c))
    \\      \u (cl-format true "\\u~4,'0x" (int c))
    \\      nil (pr c))
    \\    navigator))
    \\
    \\(defn- plain-character [params navigator offsets]
    \\  (let [[char navigator] (next-arg navigator)]
    \\    (print char)
    \\    navigator))
    \\
    \\;;; Abort handling
    \\(defn- abort? [context]
    \\  (let [token (first context)]
    \\    (or (= :up-arrow token) (= :colon-up-arrow token))))
    \\
    \\(defn- execute-sub-format [format args base-args]
    \\  (second
    \\   (map-passing-context
    \\    (fn [element context]
    \\      (if (abort? context)
    \\        [nil context]
    \\        (let [[params args] (realize-parameter-list (:params element) context)
    \\              [params offsets] (unzip-map params)
    \\              params (assoc params :base-args base-args)]
    \\          [nil (apply (:func element) [params args offsets])])))
    \\    args
    \\    format)))
    \\
    \\;;; Float support
    \\
    \\(defn- float-parts-base [f]
    \\  (let [s (.toLowerCase (str f))
    \\        exploc (.indexOf s "e")
    \\        dotloc (.indexOf s ".")]
    \\    (if (neg? exploc)
    \\      (if (neg? dotloc)
    \\        [s (str (dec (count s)))]
    \\        [(str (subs s 0 dotloc) (subs s (inc dotloc))) (str (dec dotloc))])
    \\      (if (neg? dotloc)
    \\        [(subs s 0 exploc) (subs s (inc exploc))]
    \\        [(str (subs s 0 1) (subs s 2 exploc)) (subs s (inc exploc))]))))
    \\
    \\(defn- float-parts [f]
    \\  (let [[m e] (float-parts-base f)
    \\        m1 (rtrim m \0)
    \\        m2 (ltrim m1 \0)
    \\        delta (- (count m1) (count m2))
    \\        e (if (and (pos? (count e)) (= (nth e 0) \+)) (subs e 1) e)]
    \\    (if (empty? m2)
    \\      ["0" 0]
    \\      [m2 (- (Integer/parseInt e) delta)])))
    \\
    \\(defn- inc-s [s]
    \\  (let [len-1 (dec (count s))]
    \\    (loop [i len-1]
    \\      (cond
    \\        (neg? i) (apply str "1" (repeat (inc len-1) "0"))
    \\        (= \9 (.charAt ^String s i)) (recur (dec i))
    \\        :else (apply str (subs s 0 i)
    \\                     (char (inc (int (.charAt ^String s i))))
    \\                     (repeat (- len-1 i) "0"))))))
    \\
    \\(defn- round-str [m e d w]
    \\  (if (or d w)
    \\    (let [len (count m)
    \\          w (if w (max 2 w))
    \\          round-pos (cond
    \\                      d (+ e d 1)
    \\                      (>= e 0) (max (inc e) (dec w))
    \\                      :else (+ w e))
    \\          [m1 e1 round-pos len] (if (= round-pos 0)
    \\                                  [(str "0" m) (inc e) 1 (inc len)]
    \\                                  [m e round-pos len])]
    \\      (if round-pos
    \\        (if (neg? round-pos)
    \\          ["0" 0 false]
    \\          (if (> len round-pos)
    \\            (let [round-char (nth m1 round-pos)
    \\                  result (subs m1 0 round-pos)]
    \\              (if (>= (int round-char) (int \5))
    \\                (let [round-up-result (inc-s result)
    \\                      expanded (> (count round-up-result) (count result))]
    \\                  [(if expanded
    \\                     (subs round-up-result 0 (dec (count round-up-result)))
    \\                     round-up-result)
    \\                   e1 expanded])
    \\                [result e1 false]))
    \\            [m e false]))
    \\        [m e false]))
    \\    [m e false]))
    \\
    \\(defn- expand-fixed [m e d]
    \\  (let [[m1 e1] (if (neg? e)
    \\                  [(str (apply str (repeat (dec (- e)) \0)) m) -1]
    \\                  [m e])
    \\        len (count m1)
    \\        target-len (if d (+ e1 d 1) (inc e1))]
    \\    (if (< len target-len)
    \\      (str m1 (apply str (repeat (- target-len len) \0)))
    \\      m1)))
    \\
    \\(defn- insert-decimal [m e]
    \\  (if (neg? e)
    \\    (str "." m)
    \\    (let [loc (inc e)]
    \\      (str (subs m 0 loc) "." (subs m loc)))))
    \\
    \\(defn- get-fixed [m e d]
    \\  (insert-decimal (expand-fixed m e d) e))
    \\
    \\(defn- insert-scaled-decimal [m k]
    \\  (if (neg? k)
    \\    (str "." m)
    \\    (str (subs m 0 k) "." (subs m k))))
    \\
    \\;; UPSTREAM-DIFF: uses conditional negate instead of Double/POSITIVE_INFINITY
    \\(defn- convert-ratio [x]
    \\  (if (ratio? x)
    \\    (let [d (double x)]
    \\      (if (== d 0.0)
    \\        (if (not= x 0)
    \\          (bigdec x)
    \\          d)
    \\        (if (or (== d ##Inf) (== d ##-Inf))
    \\          (bigdec x)
    \\          d)))
    \\    x))
    \\
    \\(defn- fixed-float [params navigator offsets]
    \\  (let [w (:w params)
    \\        d (:d params)
    \\        [arg navigator] (next-arg navigator)
    \\        [sign abs] (if (neg? arg) ["-" (- arg)] ["+" arg])
    \\        abs (convert-ratio abs)
    \\        [mantissa exp] (float-parts abs)
    \\        scaled-exp (+ exp (:k params))
    \\        add-sign (or (:at params) (neg? arg))
    \\        append-zero (and (not d) (<= (dec (count mantissa)) scaled-exp))
    \\        [rounded-mantissa scaled-exp expanded] (round-str mantissa scaled-exp
    \\                                                          d (if w (- w (if add-sign 1 0))))
    \\        fixed-repr (get-fixed rounded-mantissa (if expanded (inc scaled-exp) scaled-exp) d)
    \\        fixed-repr (if (and w d
    \\                            (>= d 1)
    \\                            (= (.charAt ^String fixed-repr 0) \0)
    \\                            (= (.charAt ^String fixed-repr 1) \.)
    \\                            (> (count fixed-repr) (- w (if add-sign 1 0))))
    \\                     (subs fixed-repr 1)
    \\                     fixed-repr)
    \\        prepend-zero (= (first fixed-repr) \.)]
    \\    (if w
    \\      (let [len (count fixed-repr)
    \\            signed-len (if add-sign (inc len) len)
    \\            prepend-zero (and prepend-zero (not (>= signed-len w)))
    \\            append-zero (and append-zero (not (>= signed-len w)))
    \\            full-len (if (or prepend-zero append-zero)
    \\                       (inc signed-len)
    \\                       signed-len)]
    \\        (if (and (> full-len w) (:overflowchar params))
    \\          (print (apply str (repeat w (:overflowchar params))))
    \\          (print (str
    \\                  (apply str (repeat (- w full-len) (:padchar params)))
    \\                  (if add-sign sign)
    \\                  (if prepend-zero "0")
    \\                  fixed-repr
    \\                  (if append-zero "0")))))
    \\      (print (str
    \\              (if add-sign sign)
    \\              (if prepend-zero "0")
    \\              fixed-repr
    \\              (if append-zero "0"))))
    \\    navigator))
    \\
    \\;; UPSTREAM-DIFF: uses (if (neg? arg) (- arg) arg) instead of Math/abs
    \\(defn- exponential-float [params navigator offsets]
    \\  (let [[arg navigator] (next-arg navigator)
    \\        arg (convert-ratio arg)]
    \\    (loop [[mantissa exp] (float-parts (if (neg? arg) (- arg) arg))]
    \\      (let [w (:w params)
    \\            d (:d params)
    \\            e (:e params)
    \\            k (:k params)
    \\            expchar (or (:exponentchar params) \E)
    \\            add-sign (or (:at params) (neg? arg))
    \\            prepend-zero (<= k 0)
    \\            scaled-exp (- exp (dec k))
    \\            scaled-exp-abs (if (neg? scaled-exp) (- scaled-exp) scaled-exp)
    \\            scaled-exp-str (str scaled-exp-abs)
    \\            scaled-exp-str (str expchar (if (neg? scaled-exp) \- \+)
    \\                                (if e (apply str
    \\                                             (repeat
    \\                                              (- e
    \\                                                 (count scaled-exp-str))
    \\                                              \0)))
    \\                                scaled-exp-str)
    \\            exp-width (count scaled-exp-str)
    \\            base-mantissa-width (count mantissa)
    \\            scaled-mantissa (str (apply str (repeat (- k) \0))
    \\                                 mantissa
    \\                                 (if d
    \\                                   (apply str
    \\                                          (repeat
    \\                                           (- d (dec base-mantissa-width)
    \\                                              (if (neg? k) (- k) 0)) \0))))
    \\            w-mantissa (if w (- w exp-width))
    \\            [rounded-mantissa _ incr-exp] (round-str
    \\                                           scaled-mantissa 0
    \\                                           (cond
    \\                                             (= k 0) (dec d)
    \\                                             (pos? k) d
    \\                                             (neg? k) (dec d))
    \\                                           (if w-mantissa
    \\                                             (- w-mantissa (if add-sign 1 0))))
    \\            full-mantissa (insert-scaled-decimal rounded-mantissa k)
    \\            append-zero (and (= k (count rounded-mantissa)) (nil? d))]
    \\        (if (not incr-exp)
    \\          (if w
    \\            (let [len (+ (count full-mantissa) exp-width)
    \\                  signed-len (if add-sign (inc len) len)
    \\                  prepend-zero (and prepend-zero (not (= signed-len w)))
    \\                  full-len (if prepend-zero (inc signed-len) signed-len)
    \\                  append-zero (and append-zero (< full-len w))]
    \\              (if (and (or (> full-len w) (and e (> (- exp-width 2) e)))
    \\                       (:overflowchar params))
    \\                (print (apply str (repeat w (:overflowchar params))))
    \\                (print (str
    \\                        (apply str
    \\                               (repeat
    \\                                (- w full-len (if append-zero 1 0))
    \\                                (:padchar params)))
    \\                        (if add-sign (if (neg? arg) \- \+))
    \\                        (if prepend-zero "0")
    \\                        full-mantissa
    \\                        (if append-zero "0")
    \\                        scaled-exp-str))))
    \\            (print (str
    \\                    (if add-sign (if (neg? arg) \- \+))
    \\                    (if prepend-zero "0")
    \\                    full-mantissa
    \\                    (if append-zero "0")
    \\                    scaled-exp-str)))
    \\          (recur [rounded-mantissa (inc exp)]))))
    \\    navigator))
    \\
    \\(defn- general-float [params navigator offsets]
    \\  (let [[arg _] (next-arg navigator)
    \\        arg (convert-ratio arg)
    \\        [mantissa exp] (float-parts (if (neg? arg) (- arg) arg))
    \\        w (:w params)
    \\        d (:d params)
    \\        e (:e params)
    \\        n (if (= arg 0.0) 0 (inc exp))
    \\        ee (if e (+ e 2) 4)
    \\        ww (if w (- w ee))
    \\        d (if d d (max (count mantissa) (min n 7)))
    \\        dd (- d n)]
    \\    (if (<= 0 dd d)
    \\      (let [navigator (fixed-float {:w ww :d dd :k 0
    \\                                    :overflowchar (:overflowchar params)
    \\                                    :padchar (:padchar params) :at (:at params)}
    \\                                   navigator offsets)]
    \\        (print (apply str (repeat ee \space)))
    \\        navigator)
    \\      (exponential-float params navigator offsets))))
    \\
    \\;; UPSTREAM-DIFF: uses (if (neg? arg) (- arg) arg) instead of Math/abs
    \\(defn- dollar-float [params navigator offsets]
    \\  (let [[arg navigator] (next-arg navigator)
    \\        [mantissa exp] (float-parts (if (neg? arg) (- arg) arg))
    \\        d (:d params)
    \\        n (:n params)
    \\        w (:w params)
    \\        add-sign (or (:at params) (neg? arg))
    \\        [rounded-mantissa scaled-exp expanded] (round-str mantissa exp d nil)
    \\        fixed-repr (get-fixed rounded-mantissa (if expanded (inc scaled-exp) scaled-exp) d)
    \\        full-repr (str (apply str (repeat (- n (.indexOf ^String fixed-repr ".")) \0)) fixed-repr)
    \\        full-len (+ (count full-repr) (if add-sign 1 0))]
    \\    (print (str
    \\            (if (and (:colon params) add-sign) (if (neg? arg) \- \+))
    \\            (apply str (repeat (- w full-len) (:padchar params)))
    \\            (if (and (not (:colon params)) add-sign) (if (neg? arg) \- \+))
    \\            full-repr))
    \\    navigator))
    \\
    \\;;; Conditional constructs
    \\
    \\(defn- choice-conditional [params arg-navigator offsets]
    \\  (let [arg (:selector params)
    \\        [arg navigator] (if arg [arg arg-navigator] (next-arg arg-navigator))
    \\        clauses (:clauses params)
    \\        clause (if (or (neg? arg) (>= arg (count clauses)))
    \\                 (first (:else params))
    \\                 (nth clauses arg))]
    \\    (if clause
    \\      (execute-sub-format clause navigator (:base-args params))
    \\      navigator)))
    \\
    \\(defn- boolean-conditional [params arg-navigator offsets]
    \\  (let [[arg navigator] (next-arg arg-navigator)
    \\        clauses (:clauses params)
    \\        clause (if arg
    \\                 (second clauses)
    \\                 (first clauses))]
    \\    (if clause
    \\      (execute-sub-format clause navigator (:base-args params))
    \\      navigator)))
    \\
    \\(defn- check-arg-conditional [params arg-navigator offsets]
    \\  (let [[arg navigator] (next-arg arg-navigator)
    \\        clauses (:clauses params)
    \\        clause (if arg (first clauses))]
    \\    (if arg
    \\      (if clause
    \\        (execute-sub-format clause arg-navigator (:base-args params))
    \\        arg-navigator)
    \\      navigator)))
    \\
    \\;;; Iteration constructs
    \\
    \\(defn- iterate-sublist [params navigator offsets]
    \\  (let [max-count (:max-iterations params)
    \\        param-clause (first (:clauses params))
    \\        [clause navigator] (if (empty? param-clause)
    \\                             (get-format-arg navigator)
    \\                             [param-clause navigator])
    \\        [arg-list navigator] (next-arg navigator)
    \\        args (init-navigator arg-list)]
    \\    (loop [count 0
    \\           args args
    \\           last-pos -1]
    \\      (if (and (not max-count) (= (:pos args) last-pos) (> count 1))
    \\        (throw (ex-info "%{ construct not consuming any arguments: Infinite loop!" {:type :format-error})))
    \\      (if (or (and (empty? (:rest args))
    \\                   (or (not (:colon (:right-params params))) (> count 0)))
    \\              (and max-count (>= count max-count)))
    \\        navigator
    \\        (let [iter-result (execute-sub-format clause args (:base-args params))]
    \\          (if (= :up-arrow (first iter-result))
    \\            navigator
    \\            (recur (inc count) iter-result (:pos args))))))))
    \\
    \\(defn- iterate-list-of-sublists [params navigator offsets]
    \\  (let [max-count (:max-iterations params)
    \\        param-clause (first (:clauses params))
    \\        [clause navigator] (if (empty? param-clause)
    \\                             (get-format-arg navigator)
    \\                             [param-clause navigator])
    \\        [arg-list navigator] (next-arg navigator)]
    \\    (loop [count 0
    \\           arg-list arg-list]
    \\      (if (or (and (empty? arg-list)
    \\                   (or (not (:colon (:right-params params))) (> count 0)))
    \\              (and max-count (>= count max-count)))
    \\        navigator
    \\        (let [iter-result (execute-sub-format
    \\                           clause
    \\                           (init-navigator (first arg-list))
    \\                           (init-navigator (next arg-list)))]
    \\          (if (= :colon-up-arrow (first iter-result))
    \\            navigator
    \\            (recur (inc count) (next arg-list))))))))
    \\
    \\(defn- iterate-main-list [params navigator offsets]
    \\  (let [max-count (:max-iterations params)
    \\        param-clause (first (:clauses params))
    \\        [clause navigator] (if (empty? param-clause)
    \\                             (get-format-arg navigator)
    \\                             [param-clause navigator])]
    \\    (loop [count 0
    \\           navigator navigator
    \\           last-pos -1]
    \\      (if (and (not max-count) (= (:pos navigator) last-pos) (> count 1))
    \\        (throw (ex-info "%@{ construct not consuming any arguments: Infinite loop!" {:type :format-error})))
    \\      (if (or (and (empty? (:rest navigator))
    \\                   (or (not (:colon (:right-params params))) (> count 0)))
    \\              (and max-count (>= count max-count)))
    \\        navigator
    \\        (let [iter-result (execute-sub-format clause navigator (:base-args params))]
    \\          (if (= :up-arrow (first iter-result))
    \\            (second iter-result)
    \\            (recur
    \\             (inc count) iter-result (:pos navigator))))))))
    \\
    \\(defn- iterate-main-sublists [params navigator offsets]
    \\  (let [max-count (:max-iterations params)
    \\        param-clause (first (:clauses params))
    \\        [clause navigator] (if (empty? param-clause)
    \\                             (get-format-arg navigator)
    \\                             [param-clause navigator])]
    \\    (loop [count 0
    \\           navigator navigator]
    \\      (if (or (and (empty? (:rest navigator))
    \\                   (or (not (:colon (:right-params params))) (> count 0)))
    \\              (and max-count (>= count max-count)))
    \\        navigator
    \\        (let [[sublist navigator] (next-arg-or-nil navigator)
    \\              iter-result (execute-sub-format clause (init-navigator sublist) navigator)]
    \\          (if (= :colon-up-arrow (first iter-result))
    \\            navigator
    \\            (recur (inc count) navigator)))))))
    \\
    \\;;; Logical block and justification for ~<...~>
    \\
    \\(declare format-logical-block)
    \\(declare justify-clauses)
    \\
    \\(defn- logical-block-or-justify [params navigator offsets]
    \\  (if (:colon (:right-params params))
    \\    (format-logical-block params navigator offsets)
    \\    (justify-clauses params navigator offsets)))
    \\
    \\;; UPSTREAM-DIFF: uses with-out-str instead of java.io.StringWriter binding
    \\;; UPSTREAM-DIFF: uses atom + with-out-str instead of java.io.StringWriter binding
    \\(defn- render-clauses [clauses navigator base-navigator]
    \\  (loop [clauses clauses
    \\         acc []
    \\         navigator navigator]
    \\    (if (empty? clauses)
    \\      [acc navigator]
    \\      (let [clause (first clauses)
    \\            iter-atom (atom nil)
    \\            result-str (with-out-str
    \\                         (reset! iter-atom (execute-sub-format clause navigator base-navigator)))
    \\            iter-result @iter-atom]
    \\        (if (= :up-arrow (first iter-result))
    \\          [acc (second iter-result)]
    \\          (recur (next clauses) (conj acc result-str) iter-result))))))
    \\
    \\(defn- justify-clauses [params navigator offsets]
    \\  (let [[[eol-str] new-navigator] (when-let [else (:else params)]
    \\                                    (render-clauses else navigator (:base-args params)))
    \\        navigator (or new-navigator navigator)
    \\        [else-params new-navigator] (when-let [p (:else-params params)]
    \\                                      (realize-parameter-list p navigator))
    \\        navigator (or new-navigator navigator)
    \\        min-remaining (or (first (:min-remaining else-params)) 0)
    \\        max-columns (or (first (:max-columns else-params))
    \\                        (if *pw* (get-max-column (getf *pw* :base)) 72))
    \\        clauses (:clauses params)
    \\        [strs navigator] (render-clauses clauses navigator (:base-args params))
    \\        slots (max 1
    \\                   (+ (dec (count strs)) (if (:colon params) 1 0) (if (:at params) 1 0)))
    \\        chars (reduce + (map count strs))
    \\        mincol (:mincol params)
    \\        minpad (:minpad params)
    \\        colinc (:colinc params)
    \\        minout (+ chars (* slots minpad))
    \\        result-columns (if (<= minout mincol)
    \\                         mincol
    \\                         (+ mincol (* colinc
    \\                                      (+ 1 (quot (- minout mincol 1) colinc)))))
    \\        total-pad (- result-columns chars)
    \\        pad (max minpad (quot total-pad slots))
    \\        extra-pad (- total-pad (* pad slots))
    \\        pad-str (apply str (repeat pad (:padchar params)))]
    \\    (if (and eol-str
    \\             (> (+ (if *pw* (get-column (getf *pw* :base)) 0) min-remaining result-columns)
    \\                max-columns))
    \\      (print eol-str))
    \\    (loop [slots slots
    \\           extra-pad extra-pad
    \\           strs strs
    \\           pad-only (or (:colon params)
    \\                        (and (= (count strs) 1) (not (:at params))))]
    \\      (if (seq strs)
    \\        (do
    \\          (print (str (if (not pad-only) (first strs))
    \\                      (if (or pad-only (next strs) (:at params)) pad-str)
    \\                      (if (pos? extra-pad) (:padchar params))))
    \\          (recur
    \\           (dec slots)
    \\           (dec extra-pad)
    \\           (if pad-only strs (next strs))
    \\           false))))
    \\    navigator))
    \\
    \\;;; Case modification with ~(...~)
    \\;; UPSTREAM-DIFF: uses with-out-str + string transforms instead of Java Writer proxies
    \\
    \\(defn- capitalize-string [s first?]
    \\  (let [f (first s)
    \\        s (if (and first? f (Character/isLetter ^Character f))
    \\            (str (char-upper f) (subs s 1))
    \\            s)]
    \\    (loop [result "" remaining s in-word? (and first? f (Character/isLetter ^Character f))]
    \\      (if (empty? remaining)
    \\        result
    \\        (let [c (first remaining)]
    \\          (if (Character/isWhitespace ^Character c)
    \\            (recur (str result c) (subs remaining 1) false)
    \\            (if in-word?
    \\              (recur (str result c) (subs remaining 1) true)
    \\              (recur (str result (char-upper c)) (subs remaining 1) true))))))))
    \\
    \\;; UPSTREAM-DIFF: capture output + navigator in single execution using atom
    \\(defn- modify-case [make-transform params navigator offsets]
    \\  (let [clause (first (:clauses params))
    \\        nav-result (atom nil)
    \\        result-str (with-out-str
    \\                     (reset! nav-result (execute-sub-format clause navigator (:base-args params))))
    \\        transformed (make-transform result-str)]
    \\    (print transformed)
    \\    @nav-result))
    \\
    \\;;; Pretty printer support from format
    \\
    \\(defn- format-logical-block [params navigator offsets]
    \\  (let [clauses (:clauses params)
    \\        clause-count (count clauses)
    \\        prefix (cond
    \\                 (> clause-count 1) (:string (:params (first (first clauses))))
    \\                 (:colon params) "(")
    \\        body (nth clauses (if (> clause-count 1) 1 0))
    \\        suffix (cond
    \\                 (> clause-count 2) (:string (:params (first (nth clauses 2))))
    \\                 (:colon params) ")")
    \\        [arg navigator] (next-arg navigator)]
    \\    (pprint-logical-block :prefix prefix :suffix suffix
    \\                          (execute-sub-format
    \\                           body
    \\                           (init-navigator arg)
    \\                           (:base-args params)))
    \\    navigator))
    \\
    \\(defn- set-indent [params navigator offsets]
    \\  (let [relative-to (if (:colon params) :current :block)]
    \\    (pprint-indent relative-to (:n params))
    \\    navigator))
    \\
    \\(defn- conditional-newline [params navigator offsets]
    \\  (let [kind (if (:colon params)
    \\               (if (:at params) :mandatory :fill)
    \\               (if (:at params) :miser :linear))]
    \\    (pprint-newline kind)
    \\    navigator))
    \\
    \\;;; Column-aware operations
    \\
    \\;; UPSTREAM-DIFF: uses *pw* column tracking instead of *out* column tracking
    \\(defn- absolute-tabulation [params navigator offsets]
    \\  (let [colnum (:colnum params)
    \\        colinc (:colinc params)
    \\        current (if *pw* (get-column (getf *pw* :base)) 0)
    \\        space-count (cond
    \\                      (< current colnum) (- colnum current)
    \\                      (= colinc 0) 0
    \\                      :else (- colinc (rem (- current colnum) colinc)))]
    \\    (print (apply str (repeat space-count \space))))
    \\  navigator)
    \\
    \\(defn- relative-tabulation [params navigator offsets]
    \\  (let [colrel (:colnum params)
    \\        colinc (:colinc params)
    \\        start-col (+ colrel (if *pw* (get-column (getf *pw* :base)) 0))
    \\        offset (if (pos? colinc) (rem start-col colinc) 0)
    \\        space-count (+ colrel (if (= 0 offset) 0 (- colinc offset)))]
    \\    (print (apply str (repeat space-count \space))))
    \\  navigator)
    \\
    \\;;; Directive table
    \\
    \\(defn- process-directive-table-element [[char params flags bracket-info & generator-fn]]
    \\  [char,
    \\   {:directive char,
    \\    :params `(array-map ~@params),
    \\    :flags flags,
    \\    :bracket-info bracket-info,
    \\    :generator-fn (concat '(fn [params offset]) generator-fn)}])
    \\
    \\(defmacro ^{:private true}
    \\  defdirectives
    \\  [& directives]
    \\  `(def ^{:private true}
    \\     directive-table (hash-map ~@(mapcat process-directive-table-element directives))))
    \\
    \\(defdirectives
    \\  (\A
    \\   [:mincol [0 Integer] :colinc [1 Integer] :minpad [0 Integer] :padchar [\space Character]]
    \\   #{:at :colon :both} {}
    \\   #(format-ascii print-str %1 %2 %3))
    \\
    \\  (\S
    \\   [:mincol [0 Integer] :colinc [1 Integer] :minpad [0 Integer] :padchar [\space Character]]
    \\   #{:at :colon :both} {}
    \\   #(format-ascii pr-str %1 %2 %3))
    \\
    \\  (\D
    \\   [:mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    \\    :commainterval [3 Integer]]
    \\   #{:at :colon :both} {}
    \\   #(format-integer 10 %1 %2 %3))
    \\
    \\  (\B
    \\   [:mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    \\    :commainterval [3 Integer]]
    \\   #{:at :colon :both} {}
    \\   #(format-integer 2 %1 %2 %3))
    \\
    \\  (\O
    \\   [:mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    \\    :commainterval [3 Integer]]
    \\   #{:at :colon :both} {}
    \\   #(format-integer 8 %1 %2 %3))
    \\
    \\  (\X
    \\   [:mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    \\    :commainterval [3 Integer]]
    \\   #{:at :colon :both} {}
    \\   #(format-integer 16 %1 %2 %3))
    \\
    \\  (\R
    \\   [:base [nil Integer] :mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    \\    :commainterval [3 Integer]]
    \\   #{:at :colon :both} {}
    \\   (do
    \\     (cond
    \\       (first (:base params))     #(format-integer (:base %1) %1 %2 %3)
    \\       (and (:at params) (:colon params))   #(format-old-roman %1 %2 %3)
    \\       (:at params)               #(format-new-roman %1 %2 %3)
    \\       (:colon params)            #(format-ordinal-english %1 %2 %3)
    \\       true                       #(format-cardinal-english %1 %2 %3))))
    \\
    \\  (\P
    \\   []
    \\   #{:at :colon :both} {}
    \\   (fn [params navigator offsets]
    \\     (let [navigator (if (:colon params) (relative-reposition navigator -1) navigator)
    \\           strs (if (:at params) ["y" "ies"] ["" "s"])
    \\           [arg navigator] (next-arg navigator)]
    \\       (print (if (= arg 1) (first strs) (second strs)))
    \\       navigator)))
    \\
    \\  (\C
    \\   [:char-format [nil Character]]
    \\   #{:at :colon :both} {}
    \\   (cond
    \\     (:colon params) pretty-character
    \\     (:at params) readable-character
    \\     :else plain-character))
    \\
    \\  (\F
    \\   [:w [nil Integer] :d [nil Integer] :k [0 Integer] :overflowchar [nil Character]
    \\    :padchar [\space Character]]
    \\   #{:at} {}
    \\   fixed-float)
    \\
    \\  (\E
    \\   [:w [nil Integer] :d [nil Integer] :e [nil Integer] :k [1 Integer]
    \\    :overflowchar [nil Character] :padchar [\space Character]
    \\    :exponentchar [nil Character]]
    \\   #{:at} {}
    \\   exponential-float)
    \\
    \\  (\G
    \\   [:w [nil Integer] :d [nil Integer] :e [nil Integer] :k [1 Integer]
    \\    :overflowchar [nil Character] :padchar [\space Character]
    \\    :exponentchar [nil Character]]
    \\   #{:at} {}
    \\   general-float)
    \\
    \\  (\$
    \\   [:d [2 Integer] :n [1 Integer] :w [0 Integer] :padchar [\space Character]]
    \\   #{:at :colon :both} {}
    \\   dollar-float)
    \\
    \\  (\%
    \\   [:count [1 Integer]]
    \\   #{} {}
    \\   (fn [params arg-navigator offsets]
    \\     (dotimes [i (:count params)]
    \\       (prn))
    \\     arg-navigator))
    \\
    \\  (\&
    \\   [:count [1 Integer]]
    \\   #{:pretty} {}
    \\   (fn [params arg-navigator offsets]
    \\     (let [cnt (:count params)]
    \\       (if (pos? cnt) (fresh-line))
    \\       (dotimes [i (dec cnt)]
    \\         (prn)))
    \\     arg-navigator))
    \\
    \\  (\|
    \\   [:count [1 Integer]]
    \\   #{} {}
    \\   (fn [params arg-navigator offsets]
    \\     (dotimes [i (:count params)]
    \\       (print \formfeed))
    \\     arg-navigator))
    \\
    \\  (\~
    \\   [:n [1 Integer]]
    \\   #{} {}
    \\   (fn [params arg-navigator offsets]
    \\     (let [n (:n params)]
    \\       (print (apply str (repeat n \~)))
    \\       arg-navigator)))
    \\
    \\  (\newline
    \\   []
    \\   #{:colon :at} {}
    \\   (fn [params arg-navigator offsets]
    \\     (if (:at params)
    \\       (prn))
    \\     arg-navigator))
    \\
    \\  (\T
    \\   [:colnum [1 Integer] :colinc [1 Integer]]
    \\   #{:at :pretty} {}
    \\   (if (:at params)
    \\     #(relative-tabulation %1 %2 %3)
    \\     #(absolute-tabulation %1 %2 %3)))
    \\
    \\  (\*
    \\   [:n [nil Integer]]
    \\   #{:colon :at} {}
    \\   (if (:at params)
    \\     (fn [params navigator offsets]
    \\       (let [n (or (:n params) 0)]
    \\         (absolute-reposition navigator n)))
    \\     (fn [params navigator offsets]
    \\       (let [n (or (:n params) 1)]
    \\         (relative-reposition navigator (if (:colon params) (- n) n))))))
    \\
    \\  (\?
    \\   []
    \\   #{:at} {}
    \\   (if (:at params)
    \\     (fn [params navigator offsets]
    \\       (let [[subformat navigator] (get-format-arg navigator)]
    \\         (execute-sub-format subformat navigator (:base-args params))))
    \\     (fn [params navigator offsets]
    \\       (let [[subformat navigator] (get-format-arg navigator)
    \\             [subargs navigator] (next-arg navigator)
    \\             sub-navigator (init-navigator subargs)]
    \\         (execute-sub-format subformat sub-navigator (:base-args params))
    \\         navigator))))
    \\
    \\  (\(
    \\   []
    \\   #{:colon :at :both} {:right \) :allows-separator nil :else nil}
    \\   (let [mod-case-writer (cond
    \\                           (and (:at params) (:colon params))
    \\                           (fn [s] (.toUpperCase ^String s))
    \\
    \\                           (:colon params)
    \\                           (fn [s] (capitalize-string (.toLowerCase ^String s) true))
    \\
    \\                           (:at params)
    \\                           (fn [s]
    \\                             (let [low (.toLowerCase ^String s)
    \\                                   m (re-find #"\S" low)]
    \\                               (if m
    \\                                 (let [idx (.indexOf ^String low ^String m)]
    \\                                   (str (subs low 0 idx)
    \\                                        (char-upper (nth low idx))
    \\                                        (subs low (inc idx))))
    \\                                 low)))
    \\
    \\                           :else
    \\                           (fn [s] (.toLowerCase ^String s)))]
    \\     #(modify-case mod-case-writer %1 %2 %3)))
    \\
    \\  (\) [] #{} {} nil)
    \\
    \\  (\[
    \\   [:selector [nil Integer]]
    \\   #{:colon :at} {:right \] :allows-separator true :else :last}
    \\   (cond
    \\     (:colon params)
    \\     boolean-conditional
    \\
    \\     (:at params)
    \\     check-arg-conditional
    \\
    \\     true
    \\     choice-conditional))
    \\
    \\  (\; [:min-remaining [nil Integer] :max-columns [nil Integer]]
    \\      #{:colon} {:separator true} nil)
    \\
    \\  (\] [] #{} {} nil)
    \\
    \\  (\{
    \\   [:max-iterations [nil Integer]]
    \\   #{:colon :at :both} {:right \} :allows-separator false}
    \\   (cond
    \\     (and (:at params) (:colon params))
    \\     iterate-main-sublists
    \\
    \\     (:colon params)
    \\     iterate-list-of-sublists
    \\
    \\     (:at params)
    \\     iterate-main-list
    \\
    \\     true
    \\     iterate-sublist))
    \\
    \\  (\} [] #{:colon} {} nil)
    \\
    \\  (\<
    \\   [:mincol [0 Integer] :colinc [1 Integer] :minpad [0 Integer] :padchar [\space Character]]
    \\   #{:colon :at :both :pretty} {:right \> :allows-separator true :else :first}
    \\   logical-block-or-justify)
    \\
    \\  (\> [] #{:colon} {} nil)
    \\
    \\  (\^ [:arg1 [nil Integer] :arg2 [nil Integer] :arg3 [nil Integer]]
    \\      #{:colon} {}
    \\      (fn [params navigator offsets]
    \\        (let [arg1 (:arg1 params)
    \\              arg2 (:arg2 params)
    \\              arg3 (:arg3 params)
    \\              exit (if (:colon params) :colon-up-arrow :up-arrow)]
    \\          (cond
    \\            (and arg1 arg2 arg3)
    \\            (if (<= arg1 arg2 arg3) [exit navigator] navigator)
    \\
    \\            (and arg1 arg2)
    \\            (if (= arg1 arg2) [exit navigator] navigator)
    \\
    \\            arg1
    \\            (if (= arg1 0) [exit navigator] navigator)
    \\
    \\            true
    \\            (if (if (:colon params)
    \\                  (empty? (:rest (:base-args params)))
    \\                  (empty? (:rest navigator)))
    \\              [exit navigator] navigator)))))
    \\
    \\  (\W
    \\   []
    \\   #{:at :colon :both :pretty} {}
    \\   (if (or (:at params) (:colon params))
    \\     (let [bindings (concat
    \\                     (if (:at params) [:level nil :length nil] [])
    \\                     (if (:colon params) [:pretty true] []))]
    \\       (fn [params navigator offsets]
    \\         (let [[arg navigator] (next-arg navigator)]
    \\           (if (apply write arg bindings)
    \\             [:up-arrow navigator]
    \\             navigator))))
    \\     (fn [params navigator offsets]
    \\       (let [[arg navigator] (next-arg navigator)]
    \\         (if (write-out arg)
    \\           [:up-arrow navigator]
    \\           navigator)))))
    \\
    \\  (\_
    \\   []
    \\   #{:at :colon :both} {}
    \\   conditional-newline)
    \\
    \\  (\I
    \\   [:n [0 Integer]]
    \\   #{:colon} {}
    \\   set-indent))
    \\
    \\;;; Parameter parsing and compilation
    \\
    \\(def ^{:private true}
    \\  param-pattern #"^([vV]|#|('.)|([+-]?\d+)|(?=,))")
    \\
    \\(def ^{:private true}
    \\  special-params #{:parameter-from-args :remaining-arg-count})
    \\
    \\(defn- extract-param [[s offset saw-comma]]
    \\  (let [m (re-matcher param-pattern s)
    \\        param (re-find m)]
    \\    (if param
    \\      (let [token-str (first (re-groups m))
    \\            remainder (subs s (count token-str))
    \\            new-offset (+ offset (count token-str))]
    \\        (if (not (= \, (nth remainder 0)))
    \\          [[token-str offset] [remainder new-offset false]]
    \\          [[token-str offset] [(subs remainder 1) (inc new-offset) true]]))
    \\      (if saw-comma
    \\        (format-error "Badly formed parameters in format directive" offset)
    \\        [nil [s offset]]))))
    \\
    \\(defn- extract-params [s offset]
    \\  (consume extract-param [s offset false]))
    \\
    \\(defn- translate-param [[p offset]]
    \\  [(cond
    \\     (= (count p) 0) nil
    \\     (and (= (count p) 1) (contains? #{\v \V} (nth p 0))) :parameter-from-args
    \\     (and (= (count p) 1) (= \# (nth p 0))) :remaining-arg-count
    \\     (and (= (count p) 2) (= \' (nth p 0))) (nth p 1)
    \\     true (Integer/parseInt p))
    \\   offset])
    \\
    \\(def ^{:private true}
    \\  flag-defs {\: :colon \@ :at})
    \\
    \\(defn- extract-flags [s offset]
    \\  (consume
    \\   (fn [[s offset flags]]
    \\     (if (empty? s)
    \\       [nil [s offset flags]]
    \\       (let [flag (get flag-defs (first s))]
    \\         (if flag
    \\           (if (contains? flags flag)
    \\             (format-error
    \\              (str "Flag \"" (first s) "\" appears more than once in a directive")
    \\              offset)
    \\             [true [(subs s 1) (inc offset) (assoc flags flag [true offset])]])
    \\           [nil [s offset flags]]))))
    \\   [s offset {}]))
    \\
    \\;; UPSTREAM-DIFF: use (contains? allowed :x) instead of (:x allowed) — CW keyword-as-fn on sets returns nil
    \\(defn- check-flags [def flags]
    \\  (let [allowed (:flags def)]
    \\    (if (and (not (contains? allowed :at)) (:at flags))
    \\      (format-error (str "\"@\" is an illegal flag for format directive \"" (:directive def) "\"")
    \\                    (nth (:at flags) 1)))
    \\    (if (and (not (contains? allowed :colon)) (:colon flags))
    \\      (format-error (str "\":\" is an illegal flag for format directive \"" (:directive def) "\"")
    \\                    (nth (:colon flags) 1)))
    \\    (if (and (not (contains? allowed :both)) (:at flags) (:colon flags))
    \\      (format-error (str "Cannot combine \"@\" and \":\" flags for format directive \""
    \\                         (:directive def) "\"")
    \\                    (min (nth (:colon flags) 1) (nth (:at flags) 1))))))
    \\
    \\(defn- map-params [def params flags offset]
    \\  (check-flags def flags)
    \\  (if (> (count params) (count (:params def)))
    \\    (format-error
    \\     (cl-format
    \\      nil
    \\      "Too many parameters for directive \"~C\": ~D~:* ~[were~;was~:;were~] specified but only ~D~:* ~[are~;is~:;are~] allowed"
    \\      (:directive def) (count params) (count (:params def)))
    \\     (second (first params))))
    \\  ;; UPSTREAM-DIFF: CW can't use (instance? <retrieved-symbol> val) from data structures
    \\  ;; Use type-name based check instead
    \\  (doall
    \\   (map #(let [val (first %1)
    \\               type-sym (second (second %2))]
    \\           (if (not (or (nil? val) (contains? special-params val)
    \\                        (cond
    \\                          (= type-sym 'Integer) (integer? val)
    \\                          (= type-sym 'Character) (char? val)
    \\                          :else true)))
    \\             (format-error (str "Parameter " (name (first %2))
    \\                                " has bad type in directive \"" (:directive def) "\": "
    \\                                (class val))
    \\                           (second %1))))
    \\        params (:params def)))
    \\
    \\  (merge
    \\   (into (array-map)
    \\         (reverse (for [[name [default]] (:params def)] [name [default offset]])))
    \\   (reduce #(apply assoc %1 %2) {} (filter #(first (nth % 1)) (zipmap (keys (:params def)) params)))
    \\   flags))
    \\
    \\(defn- compile-directive [s offset]
    \\  (let [[raw-params [rest offset]] (extract-params s offset)
    \\        [_ [rest offset flags]] (extract-flags rest offset)
    \\        directive (first rest)
    \\        def (get directive-table (char-upper directive))
    \\        params (if def (map-params def (map translate-param raw-params) flags offset))]
    \\    (if (not directive)
    \\      (format-error "Format string ended in the middle of a directive" offset))
    \\    (if (not def)
    \\      (format-error (str "Directive \"" directive "\" is undefined") offset))
    \\    [(struct compiled-directive ((:generator-fn def) params offset) def params offset)
    \\     (let [remainder (subs rest 1)
    \\           offset (inc offset)
    \\           trim? (and (= \newline (:directive def))
    \\                      (not (:colon params)))
    \\           trim-count (if trim? (prefix-count remainder [\space \tab]) 0)
    \\           remainder (subs remainder trim-count)
    \\           offset (+ offset trim-count)]
    \\       [remainder offset])]))
    \\
    \\(defn- compile-raw-string [s offset]
    \\  ;; UPSTREAM-DIFF: use cw-write instead of print to route through *pw* pretty-writer
    \\  (struct compiled-directive (fn [_ a _] (cw-write s) a) nil {:string s} offset))
    \\
    \\(defn- right-bracket [this] (:right (:bracket-info (:def this))))
    \\(defn- separator? [this] (:separator (:bracket-info (:def this))))
    \\(defn- else-separator? [this]
    \\  (and (:separator (:bracket-info (:def this)))
    \\       (:colon (:params this))))
    \\
    \\(declare collect-clauses)
    \\
    \\(defn- process-bracket [this remainder]
    \\  (let [[subex remainder] (collect-clauses (:bracket-info (:def this))
    \\                                           (:offset this) remainder)]
    \\    [(struct compiled-directive
    \\             (:func this) (:def this)
    \\             (merge (:params this) (tuple-map subex (:offset this)))
    \\             (:offset this))
    \\     remainder]))
    \\
    \\(defn- process-clause [bracket-info offset remainder]
    \\  (consume
    \\   (fn [remainder]
    \\     (if (empty? remainder)
    \\       (format-error "No closing bracket found." offset)
    \\       (let [this (first remainder)
    \\             remainder (next remainder)]
    \\         (cond
    \\           (right-bracket this)
    \\           (process-bracket this remainder)
    \\
    \\           (= (:right bracket-info) (:directive (:def this)))
    \\           [nil [:right-bracket (:params this) nil remainder]]
    \\
    \\           (else-separator? this)
    \\           [nil [:else nil (:params this) remainder]]
    \\
    \\           (separator? this)
    \\           [nil [:separator nil nil remainder]]
    \\
    \\           true
    \\           [this remainder]))))
    \\   remainder))
    \\
    \\(defn- collect-clauses [bracket-info offset remainder]
    \\  (second
    \\   (consume
    \\    (fn [[clause-map saw-else remainder]]
    \\      (let [[clause [type right-params else-params remainder]]
    \\            (process-clause bracket-info offset remainder)]
    \\        (cond
    \\          (= type :right-bracket)
    \\          [nil [(merge-with into clause-map
    \\                            {(if saw-else :else :clauses) [clause]
    \\                             :right-params right-params})
    \\                remainder]]
    \\
    \\          (= type :else)
    \\          (cond
    \\            (:else clause-map)
    \\            (format-error "Two else clauses (\"~:;\") inside bracket construction." offset)
    \\
    \\            (not (:else bracket-info))
    \\            (format-error "An else clause (\"~:;\") is in a bracket type that doesn't support it."
    \\                          offset)
    \\
    \\            (and (= :first (:else bracket-info)) (seq (:clauses clause-map)))
    \\            (format-error
    \\             "The else clause (\"~:;\") is only allowed in the first position for this directive."
    \\             offset)
    \\
    \\            true
    \\            (if (= :first (:else bracket-info))
    \\              [true [(merge-with into clause-map {:else [clause] :else-params else-params})
    \\                     false remainder]]
    \\              [true [(merge-with into clause-map {:clauses [clause]})
    \\                     true remainder]]))
    \\
    \\          (= type :separator)
    \\          (cond
    \\            saw-else
    \\            (format-error "A plain clause (with \"~;\") follows an else clause (\"~:;\") inside bracket construction." offset)
    \\
    \\            (not (:allows-separator bracket-info))
    \\            (format-error "A separator (\"~;\") is in a bracket type that doesn't support it."
    \\                          offset)
    \\
    \\            true
    \\            [true [(merge-with into clause-map {:clauses [clause]})
    \\                   false remainder]]))))
    \\    [{:clauses []} false remainder])))
    \\
    \\(defn- process-nesting [format]
    \\  (first
    \\   (consume
    \\    (fn [remainder]
    \\      (let [this (first remainder)
    \\            remainder (next remainder)
    \\            bracket (:bracket-info (:def this))]
    \\        (if (:right bracket)
    \\          (process-bracket this remainder)
    \\          [this remainder])))
    \\    format)))
    \\
    \\(defn- compile-format [format-str]
    \\  (binding [*format-str* format-str]
    \\    (process-nesting
    \\     (first
    \\      (consume
    \\       (fn [[s offset]]
    \\         (if (empty? s)
    \\           [nil s]
    \\           (let [tilde (.indexOf ^String s "~")]
    \\             (cond
    \\               (neg? tilde) [(compile-raw-string s offset) ["" (+ offset (count s))]]
    \\               (zero? tilde) (compile-directive (subs s 1) (inc offset))
    \\               true
    \\               [(compile-raw-string (subs s 0 tilde) offset) [(subs s tilde) (+ tilde offset)]]))))
    \\       [format-str 0])))))
    \\
    \\(defn- needs-pretty [format]
    \\  (loop [format format]
    \\    (if (empty? format)
    \\      false
    \\      (if (or (:pretty (:flags (:def (first format))))
    \\              (some needs-pretty (first (:clauses (:params (first format)))))
    \\              (some needs-pretty (first (:else (:params (first format))))))
    \\        true
    \\        (recur (next format))))))
    \\
    \\;; UPSTREAM-DIFF: CW uses *pw* pretty-writer binding instead of *out* Writer rebinding
    \\(defn- execute-format
    \\  ([stream format args]
    \\   (let [sb (if (not stream) true nil)]
    \\     (if sb
    \\       ;; output to string
    \\       (with-out-str
    \\         (if (and (needs-pretty format) *print-pretty*)
    \\           (let [pw (make-pretty-writer nil *print-right-margin* *print-miser-width*)]
    \\             (binding [*pw* pw]
    \\               (execute-format format args))
    \\             (pw-ppflush pw))
    \\           (execute-format format args)))
    \\       ;; output to *out* (stream is true or a writer)
    \\       (do
    \\         (if (and (needs-pretty format) *print-pretty*)
    \\           (let [pw (make-pretty-writer nil *print-right-margin* *print-miser-width*)]
    \\             (binding [*pw* pw]
    \\               (execute-format format args))
    \\             (pw-ppflush pw))
    \\           (execute-format format args))
    \\         nil))))
    \\  ([format args]
    \\   (map-passing-context
    \\    (fn [element context]
    \\      (if (abort? context)
    \\        [nil context]
    \\        (let [[params args] (realize-parameter-list
    \\                             (:params element) context)
    \\              [params offsets] (unzip-map params)
    \\              params (assoc params :base-args args)]
    \\          [nil (apply (:func element) [params args offsets])])))
    \\    args
    \\    format)
    \\   nil))
    \\
    \\(def ^{:private true} cached-compile (memoize compile-format))
    \\
    \\(defn cl-format
    \\  "An implementation of a Common Lisp compatible format function. cl-format formats its
    \\arguments to an output stream or string based on the format control string given. It
    \\supports sophisticated formatting of structured data.
    \\
    \\Writer is an instance of java.io.Writer, true to output to *out* or nil to output
    \\to a string, format-in is the format control string and the remaining arguments
    \\are the data to be formatted.
    \\
    \\The format control string is a string to be output with embedded 'format directives'
    \\describing how to format the various arguments passed in.
    \\
    \\If writer is nil, cl-format returns the formatted result string. Otherwise, cl-format
    \\returns nil."
    \\  {:added "1.2"}
    \\  [writer format-in & args]
    \\  (let [compiled-format (if (string? format-in) (compile-format format-in) format-in)
    \\        navigator (init-navigator args)]
    \\    (execute-format writer compiled-format navigator)))
    \\
    \\(defmacro formatter
    \\  "Makes a function which can directly run format-in. The function is
    \\fn [stream & args] ... and returns nil unless the stream is nil (meaning
    \\output to a string) in which case it returns the resulting string.
    \\
    \\format-in can be either a control string or a previously compiled format."
    \\  {:added "1.2"}
    \\  [format-in]
    \\  `(let [format-in# ~format-in
    \\         ;; UPSTREAM-DIFF: direct fn refs instead of ns-interns lookup
    \\         my-c-c# cached-compile
    \\         my-e-f# execute-format
    \\         my-i-n# init-navigator
    \\         cf# (if (string? format-in#) (my-c-c# format-in#) format-in#)]
    \\     (fn [stream# & args#]
    \\       (let [navigator# (my-i-n# args#)]
    \\         (my-e-f# stream# cf# navigator#)))))
    \\
    \\(defmacro formatter-out
    \\  "Makes a function which can directly run format-in. The function is
    \\fn [& args] ... and returns nil. This version of the formatter macro is
    \\designed to be used with *out* set to an appropriate Writer. In particular,
    \\this is meant to be used as part of a pretty printer dispatch method.
    \\
    \\format-in can be either a control string or a previously compiled format."
    \\  {:added "1.2"}
    \\  [format-in]
    \\  `(let [format-in# ~format-in
    \\         cf# (if (string? format-in#) (cached-compile format-in#) format-in#)]
    \\     (fn [& args#]
    \\       (let [navigator# (init-navigator args#)]
    \\         (execute-format cf# navigator#)))))
    \\
    \\;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    \\;;; code-dispatch — pretty print dispatch for Clojure code
    \\;;; UPSTREAM-DIFF: CW port of dispatch.clj (code-dispatch portions)
    \\;;; Adaptations: predicate-based dispatch instead of multimethod on class,
    \\;;;   cw-write instead of .write ^java.io.Writer, no Java array/IDeref support
    \\;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    \\
    \\(declare pprint-simple-code-list)
    \\
    \\;;; code-dispatch helper: format binding forms like let, loop, etc.
    \\(defn- pprint-binding-form [binding-vec]
    \\  (pprint-logical-block :prefix "[" :suffix "]"
    \\                        (print-length-loop [binding binding-vec]
    \\                                           (when (seq binding)
    \\                                             (pprint-logical-block binding
    \\                                                                   (write-out (first binding))
    \\                                                                   (when (next binding)
    \\                                                                     (cw-write " ")
    \\                                                                     (pprint-newline :miser)
    \\                                                                     (write-out (second binding))))
    \\                                             (when (next (rest binding))
    \\                                               (cw-write " ")
    \\                                               (pprint-newline :linear)
    \\                                               (recur (next (rest binding))))))))
    \\
    \\;;; code-dispatch: hold-first form (def, defonce, ->, .., locking, struct, struct-map)
    \\(defn- pprint-hold-first [alis]
    \\  (pprint-logical-block :prefix "(" :suffix ")"
    \\                        (pprint-indent :block 1)
    \\                        (write-out (first alis))
    \\                        (when (next alis)
    \\                          (cw-write " ")
    \\                          (pprint-newline :miser)
    \\                          (write-out (second alis))
    \\                          (when (next (rest alis))
    \\                            (cw-write " ")
    \\                            (pprint-newline :linear)
    \\                            (print-length-loop [alis (next (rest alis))]
    \\                                               (when alis
    \\                                                 (write-out (first alis))
    \\                                                 (when (next alis)
    \\                                                   (cw-write " ")
    \\                                                   (pprint-newline :linear)
    \\                                                   (recur (next alis)))))))))
    \\
    \\;;; code-dispatch: defn/defmacro/fn
    \\(defn- single-defn [alis has-doc-str?]
    \\  (when (seq alis)
    \\    (if has-doc-str?
    \\      ((formatter-out " ~_"))
    \\      ((formatter-out " ~@_")))
    \\    ((formatter-out "~{~w~^ ~_~}") alis)))
    \\
    \\(defn- multi-defn [alis has-doc-str?]
    \\  (when (seq alis)
    \\    ((formatter-out " ~_~{~w~^ ~_~}") alis)))
    \\
    \\(defn- pprint-defn [alis]
    \\  (if (next alis)
    \\    (let [[defn-sym defn-name & stuff] alis
    \\          [doc-str stuff] (if (string? (first stuff))
    \\                            [(first stuff) (next stuff)]
    \\                            [nil stuff])
    \\          [attr-map stuff] (if (map? (first stuff))
    \\                             [(first stuff) (next stuff)]
    \\                             [nil stuff])]
    \\      (pprint-logical-block :prefix "(" :suffix ")"
    \\                            ((formatter-out "~w ~1I~@_~w") defn-sym defn-name)
    \\                            (when doc-str
    \\                              ((formatter-out " ~_~w") doc-str))
    \\                            (when attr-map
    \\                              ((formatter-out " ~_~w") attr-map))
    \\                            (cond
    \\                              (vector? (first stuff)) (single-defn stuff (or doc-str attr-map))
    \\                              :else (multi-defn stuff (or doc-str attr-map)))))
    \\    (pprint-simple-code-list alis)))
    \\
    \\;;; code-dispatch: let/loop/binding/with-open/when-let/if-let/doseq/dotimes
    \\(defn- pprint-let [alis]
    \\  (let [base-sym (first alis)]
    \\    (pprint-logical-block :prefix "(" :suffix ")"
    \\                          (if (and (next alis) (vector? (second alis)))
    \\                            (do
    \\                              ((formatter-out "~w ~1I~@_") base-sym)
    \\                              (pprint-binding-form (second alis))
    \\                              ((formatter-out " ~_~{~w~^ ~_~}") (next (rest alis))))
    \\                            (pprint-simple-code-list alis)))))
    \\
    \\;;; code-dispatch: if/if-not/when/when-not
    \\(defn- pprint-if [alis]
    \\  (pprint-logical-block :prefix "(" :suffix ")"
    \\                        (pprint-indent :block 1)
    \\                        (write-out (first alis))
    \\                        (when (next alis)
    \\                          (cw-write " ")
    \\                          (pprint-newline :miser)
    \\                          (write-out (second alis))
    \\                          (doseq [clause (next (rest alis))]
    \\                            (cw-write " ")
    \\                            (pprint-newline :linear)
    \\                            (write-out clause)))))
    \\
    \\;;; code-dispatch: cond
    \\(defn- pprint-cond [alis]
    \\  (pprint-logical-block :prefix "(" :suffix ")"
    \\                        (pprint-indent :block 1)
    \\                        (write-out (first alis))
    \\                        (when (next alis)
    \\                          (cw-write " ")
    \\                          (pprint-newline :linear)
    \\                          (print-length-loop [alis (next alis)]
    \\                                             (when alis
    \\                                               (pprint-logical-block alis
    \\                                                                     (write-out (first alis))
    \\                                                                     (when (next alis)
    \\                                                                       (cw-write " ")
    \\                                                                       (pprint-newline :miser)
    \\                                                                       (write-out (second alis))))
    \\                                               (when (next (rest alis))
    \\                                                 (cw-write " ")
    \\                                                 (pprint-newline :linear)
    \\                                                 (recur (next (rest alis)))))))))
    \\
    \\;;; code-dispatch: condp
    \\(defn- pprint-condp [alis]
    \\  (if (> (count alis) 3)
    \\    (pprint-logical-block :prefix "(" :suffix ")"
    \\                          (pprint-indent :block 1)
    \\                          (apply (formatter-out "~w ~@_~w ~@_~w ~_") alis)
    \\                          (print-length-loop [alis (seq (drop 3 alis))]
    \\                                             (when alis
    \\                                               (pprint-logical-block alis
    \\                                                                     (write-out (first alis))
    \\                                                                     (when (next alis)
    \\                                                                       (cw-write " ")
    \\                                                                       (pprint-newline :miser)
    \\                                                                       (write-out (second alis))))
    \\                                               (when (next (rest alis))
    \\                                                 (cw-write " ")
    \\                                                 (pprint-newline :linear)
    \\                                                 (recur (next (rest alis)))))))
    \\    (pprint-simple-code-list alis)))
    \\
    \\;;; code-dispatch: #() anonymous functions
    \\(def ^:dynamic ^{:private true} *symbol-map* {})
    \\
    \\(defn- pprint-anon-func [alis]
    \\  (let [args (second alis)
    \\        nlis (first (rest (rest alis)))]
    \\    (if (vector? args)
    \\      (binding [*symbol-map* (if (= 1 (count args))
    \\                               {(first args) "%"}
    \\                               (into {}
    \\                                     (map
    \\                                      #(vector %1 (str \% %2))
    \\                                      args
    \\                                      (range 1 (inc (count args))))))]
    \\        ((formatter-out "~<#(~;~@{~w~^ ~_~}~;)~:>") nlis))
    \\      (pprint-simple-code-list alis))))
    \\
    \\;;; code-dispatch: ns macro
    \\(defn- brackets [form]
    \\  (if (vector? form) ["[" "]"] ["(" ")"]))
    \\
    \\(defn- pprint-ns-reference [reference]
    \\  (if (sequential? reference)
    \\    (let [[start end] (brackets reference)
    \\          [keyw & args] reference]
    \\      (pprint-logical-block :prefix start :suffix end
    \\                            ((formatter-out "~w~:i") keyw)
    \\                            (loop [args args]
    \\                              (when (seq args)
    \\                                ((formatter-out " "))
    \\                                (let [arg (first args)]
    \\                                  (if (sequential? arg)
    \\                                    (let [[start end] (brackets arg)]
    \\                                      (pprint-logical-block :prefix start :suffix end
    \\                                                            (if (and (= (count arg) 3) (keyword? (second arg)))
    \\                                                              (let [[ns kw lis] arg]
    \\                                                                ((formatter-out "~w ~w ") ns kw)
    \\                                                                (if (sequential? lis)
    \\                                                                  ((formatter-out (if (vector? lis)
    \\                                                                                    "~<[~;~@{~w~^ ~:_~}~;]~:>"
    \\                                                                                    "~<(~;~@{~w~^ ~:_~}~;)~:>"))
    \\                                                                   lis)
    \\                                                                  (write-out lis)))
    \\                                                              (apply (formatter-out "~w ~:i~@{~w~^ ~:_~}") arg)))
    \\                                      (when (next args) ((formatter-out "~_"))))
    \\                                    (do
    \\                                      (write-out arg)
    \\                                      (when (next args) ((formatter-out "~:_"))))))
    \\                                (recur (next args))))))
    \\    (when reference (write-out reference))))
    \\
    \\(defn- pprint-ns [alis]
    \\  (if (next alis)
    \\    (let [[ns-sym ns-name & stuff] alis
    \\          [doc-str stuff] (if (string? (first stuff))
    \\                            [(first stuff) (next stuff)]
    \\                            [nil stuff])
    \\          [attr-map references] (if (map? (first stuff))
    \\                                  [(first stuff) (next stuff)]
    \\                                  [nil stuff])]
    \\      (pprint-logical-block :prefix "(" :suffix ")"
    \\                            ((formatter-out "~w ~1I~@_~w") ns-sym ns-name)
    \\                            (when (or doc-str attr-map (seq references))
    \\                              ((formatter-out "~@:_")))
    \\                            (when doc-str
    \\                              (cl-format true "\"~a\"~:[~;~:@_~]" doc-str (or attr-map (seq references))))
    \\                            (when attr-map
    \\                              ((formatter-out "~w~:[~;~:@_~]") attr-map (seq references)))
    \\                            (loop [references references]
    \\                              (pprint-ns-reference (first references))
    \\                              (when-let [references (next references)]
    \\                                (pprint-newline :linear)
    \\                                (recur references)))))
    \\    (write-out alis)))
    \\
    \\;;; Master code-dispatch list
    \\(defn- pprint-simple-code-list [alis]
    \\  (pprint-logical-block :prefix "(" :suffix ")"
    \\                        (pprint-indent :block 1)
    \\                        (print-length-loop [alis (seq alis)]
    \\                                           (when alis
    \\                                             (write-out (first alis))
    \\                                             (when (next alis)
    \\                                               (cw-write " ")
    \\                                               (pprint-newline :linear)
    \\                                               (recur (next alis)))))))
    \\
    \\(defn- two-forms [amap]
    \\  (into {}
    \\        (mapcat
    \\         identity
    \\         (for [x amap]
    \\           [x [(symbol (name (first x))) (second x)]]))))
    \\
    \\(defn- add-core-ns [amap]
    \\  (let [core "clojure.core"]
    \\    (into {}
    \\          (map #(let [[s f] %]
    \\                  (if (not (or (namespace s) (special-symbol? s)))
    \\                    [(symbol core (name s)) f]
    \\                    %))
    \\               amap))))
    \\
    \\(def ^:dynamic ^{:private true} *code-table*
    \\  (two-forms
    \\   (add-core-ns
    \\    {'def pprint-hold-first, 'defonce pprint-hold-first,
    \\     'defn pprint-defn, 'defn- pprint-defn, 'defmacro pprint-defn, 'fn pprint-defn,
    \\     'let pprint-let, 'loop pprint-let, 'binding pprint-let,
    \\     'with-local-vars pprint-let, 'with-open pprint-let, 'when-let pprint-let,
    \\     'if-let pprint-let, 'doseq pprint-let, 'dotimes pprint-let,
    \\     'when-first pprint-let,
    \\     'if pprint-if, 'if-not pprint-if, 'when pprint-if, 'when-not pprint-if,
    \\     'cond pprint-cond, 'condp pprint-condp,
    \\     'fn* pprint-anon-func,
    \\     '. pprint-hold-first, '.. pprint-hold-first, '-> pprint-hold-first,
    \\     'locking pprint-hold-first, 'struct pprint-hold-first,
    \\     'struct-map pprint-hold-first, 'ns pprint-ns})))
    \\
    \\(defn- pprint-code-list [alis]
    \\  (if-not (let [reader-macros {'quote "'" 'clojure.core/deref "@"
    \\                               'var "#'" 'clojure.core/unquote "~"}
    \\                macro-char (reader-macros (first alis))]
    \\            (when (and macro-char (= 2 (count alis)))
    \\              (cw-write macro-char)
    \\              (write-out (second alis))
    \\              true))
    \\    (if-let [special-form (get *code-table* (first alis))]
    \\      (special-form alis)
    \\      (pprint-simple-code-list alis))))
    \\
    \\(defn- pprint-code-symbol [sym]
    \\  (if-let [arg-num (get *symbol-map* sym)]
    \\    (cw-write (str arg-num))
    \\    (if *print-suppress-namespaces*
    \\      (cw-write (name sym))
    \\      (cw-write (pr-str sym)))))
    \\
    \\(defn code-dispatch
    \\  "The pretty print dispatch function for pretty printing Clojure code."
    \\  {:added "1.2"}
    \\  [object]
    \\  (cond
    \\    (nil? object) (cw-write (pr-str nil))
    \\    (seq? object) (pprint-code-list object)
    \\    (symbol? object) (pprint-code-symbol object)
    \\    (vector? object) (pprint-vector object)
    \\    (map? object) (pprint-map object)
    \\    (set? object) (pprint-set object)
    \\    :else (pprint-simple-default object)))
    \\
    \\;; print-table
    \\
    \\(defn print-table
    \\  "Prints a collection of maps in a textual table. Prints table headings
    \\   ks, and then a line of output for each row, corresponding to the keys
    \\   in ks. If ks are not specified, use the keys of the first item in rows."
    \\  ([ks rows]
    \\   (when (seq rows)
    \\     (let [widths (map
    \\                   (fn [k]
    \\                     (apply max (count (str k)) (map #(count (str (get % k))) rows)))
    \\                   ks)
    \\           spacers (map #(apply str (repeat % "-")) widths)
    \\           fmts (map #(str "%" % "s") widths)
    \\           fmt-row (fn [leader divider trailer row]
    \\                     (str leader
    \\                          (apply str (interpose divider
    \\                                                (for [[col fmt] (map vector (map #(get row %) ks) fmts)]
    \\                                                  (format fmt (str col)))))
    \\                          trailer))]
    \\       (println)
    \\       (println (fmt-row "| " " | " " |" (zipmap ks ks)))
    \\       (println (fmt-row "|-" "-+-" "-|" (zipmap ks spacers)))
    \\       (doseq [row rows]
    \\         (println (fmt-row "| " " | " " |" row))))))
    \\  ([rows] (print-table (keys (first rows)) rows)))
;

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
