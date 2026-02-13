;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

(ns
 ^{:doc "The spec library specifies the structure of data or functions and provides
  operations to validate, conform, explain, describe, and generate data based on
  the specs.

  Rationale: https://clojure.org/about/spec
  Guide: https://clojure.org/guides/spec"}
 clojure.spec.alpha
  (:refer-clojure :exclude [+ * and assert or cat def keys merge])
  (:require [clojure.walk :as walk]
            [clojure.spec.gen.alpha :as gen]
            [clojure.string :as str]))

(alias 'c 'clojure.core)

;; CLJW: (set! *warn-on-reflection* true) — not applicable in CW

(c/def ^:dynamic *recursion-limit*
  "A soft limit on how many times a branching spec (or/alt/*/opt-keys/multi-spec)
  can be recursed through during generation. After this a
  non-recursive branch will be chosen."
  4)

(c/def ^:dynamic *fspec-iterations*
  "The number of times an anonymous fn specified by fspec will be (generatively) tested during conform"
  21)

(c/def ^:dynamic *coll-check-limit*
  "The number of elements validated in a collection spec'ed with 'every'"
  101)

(c/def ^:dynamic *coll-error-limit*
  "The number of errors reported by explain in a collection spec'ed with 'every'"
  20)

(defprotocol Spec
  (conform* [spec x])
  (unform* [spec y])
  (explain* [spec path via in x])
  (gen* [spec overrides path rmap])
  (with-gen* [spec gfn])
  (describe* [spec]))

(defonce ^:private registry-ref (atom {}))

(defn- deep-resolve [reg k]
  (loop [spec k]
    (if (ident? spec)
      (recur (get reg spec))
      spec)))

(defn- reg-resolve
  "returns the spec/regex at end of alias chain starting with k, nil if not found, k if k not ident"
  [k]
  (if (ident? k)
    (let [reg @registry-ref
          spec (get reg k)]
      (if-not (ident? spec)
        spec
        (deep-resolve reg spec)))
    k))

(defn- reg-resolve!
  "returns the spec/regex at end of alias chain starting with k, throws if not found, k if k not ident"
  [k]
  (if (ident? k)
    (c/or (reg-resolve k)
          (throw (ex-info (str "Unable to resolve spec: " k) {:spec k}))) ;; CLJW: ex-info instead of Exception.
    k))

(defn spec?
  "returns x if x is a spec object, else logical false"
  [x]
  ;; CLJW: (satisfies? Spec x) instead of (instance? clojure.spec.alpha.Spec x)
  (when (satisfies? Spec x)
    x))

(defn regex?
  "returns x if x is a (clojure.spec) regex op, else logical false"
  [x]
  (c/and (::op x) x))

;; CLJW: Helper to check if an object supports with-meta (replaces instance? IObj)
(defn- meta-obj? [x]
  (c/or (map? x) (vector? x) (list? x) (set? x) (symbol? x) (fn? x) (seq? x)))

(defn- with-name [spec name]
  (cond
    (ident? spec) spec
    (regex? spec) (assoc spec ::name name)

   ;; CLJW: meta-obj? instead of (instance? clojure.lang.IObj spec)
    (meta-obj? spec)
    (with-meta spec (assoc (meta spec) ::name name))))

(defn- spec-name [spec]
  (cond
    (ident? spec) spec

    (regex? spec) (::name spec)

   ;; CLJW: meta-obj? instead of (instance? clojure.lang.IObj spec)
    (meta-obj? spec)
    (-> (meta spec) ::name)))

(declare spec-impl)
(declare regex-spec-impl)

(defn- maybe-spec
  "spec-or-k must be a spec, regex or resolvable kw/sym, else returns nil."
  [spec-or-k]
  (let [s (c/or (c/and (ident? spec-or-k) (reg-resolve spec-or-k))
                (spec? spec-or-k)
                (regex? spec-or-k)
                nil)]
    (if (regex? s)
      (with-name (regex-spec-impl s nil) (spec-name s))
      s)))

(defn- the-spec
  "spec-or-k must be a spec, regex or kw/sym, else returns nil. Throws if unresolvable kw/sym"
  [spec-or-k]
  (c/or (maybe-spec spec-or-k)
        (when (ident? spec-or-k)
          (throw (ex-info (str "Unable to resolve spec: " spec-or-k) {:spec spec-or-k}))))) ;; CLJW: ex-info

(defprotocol Specize
  (specize* [_] [_ form]))

;; CLJW: fn-sym — In JVM this decompiles class names.
;; CW functions don't carry class names; return nil (uses ::unknown in specize).
;; UPSTREAM-DIFF: fn-sym always returns nil
(defn- fn-sym [f]
  nil)

(extend-protocol Specize
  Keyword
  (specize* ([k] (specize* (reg-resolve! k)))
    ([k _] (specize* (reg-resolve! k))))

  Symbol
  (specize* ([s] (specize* (reg-resolve! s)))
    ([s _] (specize* (reg-resolve! s))))

  PersistentHashSet
  (specize* ([s] (spec-impl s s nil nil))
    ([s form] (spec-impl form s nil nil)))

  Object
  (specize* ([o] (if (c/and (not (map? o)) (ifn? o))
                   (if-let [s (fn-sym o)]
                     (spec-impl s o nil nil)
                     (spec-impl ::unknown o nil nil))
                   (spec-impl ::unknown o nil nil)))
    ([o form] (spec-impl form o nil nil))))

(defn- specize
  ([s] (c/or (spec? s) (specize* s)))
  ([s form] (c/or (spec? s) (specize* s form))))

(defn invalid?
  "tests the validity of a conform return value"
  [ret]
  (identical? ::invalid ret))

(defn conform
  "Given a spec and a value, returns :clojure.spec.alpha/invalid
	if value does not match spec, else the (possibly destructured) value."
  [spec x]
  (conform* (specize spec) x))

(defn unform
  "Given a spec and a value created by or compliant with a call to
  'conform' with the same spec, returns a value with all conform
  destructuring undone."
  [spec x]
  (unform* (specize spec) x))

(defn form
  "returns the spec as data"
  [spec]
  ;;TODO - incorporate gens
  (describe* (specize spec)))

(defn abbrev [form]
  (cond
    (seq? form)
    (walk/postwalk (fn [form]
                     (cond
                       (c/and (symbol? form) (namespace form))
                       (-> form name symbol)

                       (c/and (seq? form) (= 'fn (first form)) (= '[%] (second form)))
                       (last form)

                       :else form))
                   form)

    (c/and (symbol? form) (namespace form))
    (-> form name symbol)

    :else form))

(defn describe
  "returns an abbreviated description of the spec as data"
  [spec]
  (abbrev (form spec)))

(defn with-gen
  "Takes a spec and a no-arg, generator-returning fn and returns a version of that spec that uses that generator"
  [spec gen-fn]
  (let [spec (reg-resolve spec)]
    (if (regex? spec)
      (assoc spec ::gfn gen-fn)
      (with-gen* (specize spec) gen-fn))))

(defn explain-data* [spec path via in x]
  (let [probs (explain* (specize spec) path via in x)]
    (when-not (empty? probs)
      {::problems probs
       ::spec spec
       ::value x})))

(defn explain-data
  "Given a spec and a value x which ought to conform, returns nil if x
  conforms, else a map with at least the key ::problems whose value is
  a collection of problem-maps, where problem-map has at least :path :pred and :val
  keys describing the predicate and the value that failed at that
  path."
  [spec x]
  (explain-data* spec [] (if-let [name (spec-name spec)] [name] []) [] x))

(defn explain-printer
  "Default printer for explain-data. nil indicates a successful validation."
  [ed]
  (if ed
    (let [problems (->> (::problems ed)
                        (sort-by #(- (count (:in %))))
                        (sort-by #(- (count (:path %)))))]
      ;;(prn {:ed ed})
      (doseq [{:keys [path pred val reason via in] :as prob} problems]
        (pr val)
        (print " - failed: ")
        (if reason (print reason) (pr (abbrev pred)))
        (when-not (empty? in)
          (print (str " in: " (pr-str in))))
        (when-not (empty? path)
          (print (str " at: " (pr-str path))))
        (when-not (empty? via)
          (print (str " spec: " (pr-str (last via)))))
        (doseq [[k v] prob]
          (when-not (#{:path :pred :val :reason :via :in} k)
            (print "\n\t" (pr-str k) " ")
            (pr v)))
        (newline)))
    (println "Success!")))

(c/def ^:dynamic *explain-out* explain-printer)

(defn explain-out
  "Prints explanation data (per 'explain-data') to *out* using the printer in *explain-out*,
   by default explain-printer."
  [ed]
  (*explain-out* ed))

(defn explain
  "Given a spec and a value that fails to conform, prints an explanation to *out*."
  [spec x]
  (explain-out (explain-data spec x)))

(defn explain-str
  "Given a spec and a value that fails to conform, returns an explanation as a string."
  [spec x]
  (with-out-str (explain spec x)))

(declare valid?)

(defn- gensub
  [spec overrides path rmap form]
  ;; CLJW: gen depends on test.check — stub to throw
  (let [spec (specize spec)]
    (if-let [g (c/or (when-let [gfn (c/or (get overrides (c/or (spec-name spec) spec))
                                          (get overrides path))]
                       (gfn))
                     (gen* spec overrides path rmap))]
      (gen/such-that #(valid? spec %) g 100)
      (let [abbr (abbrev form)]
        (throw (ex-info (str "Unable to construct gen at: " path " for: " abbr)
                        {::path path ::form form ::failure :no-gen}))))))

(defn gen
  "Given a spec, returns the generator for it, or throws if none can
  be constructed. Optionally an overrides map can be provided which
  should map spec names or paths (vectors of keywords) to no-arg
  generator-creating fns. These will be used instead of the generators at those
  names/paths. Note that parent generator (in the spec or overrides
  map) will supersede those of any subtrees. A generator for a regex
  op must always return a sequential collection (i.e. a generator for
  s/? should return either an empty sequence/vector or a
  sequence/vector with one item in it)"
  ([spec] (gen spec nil))
  ([spec overrides] (gensub spec overrides [] {::recursion-limit *recursion-limit*} spec)))

(defn- ->sym
  "Returns a symbol from a symbol or var"
  [x]
  (if (var? x)
    (let [v x] ;; CLJW: adapted — var→symbol via meta
      (symbol (str (:ns (meta v))) (str (:name (meta v)))))
    x))

(defn- unfn [expr]
  (if (c/and (seq? expr)
             (symbol? (first expr))
             (= "fn*" (name (first expr))))
    (let [[[s] & form] (rest expr)]
      (conj (walk/postwalk-replace {s '%} form) '[%] 'fn))
    expr))

(defn- res [form]
  (cond
    (keyword? form) form
    (symbol? form) (c/or (-> form resolve ->sym) form)
    (sequential? form) (walk/postwalk #(if (symbol? %) (res %) %) (unfn form))
    :else form))

;; CLJW: ^:skip-wiki removed (CW defn doesn't support name metadata)
(defn def-impl
  "Do not call this directly, use 'def'"
  [k form spec]
  (c/assert (c/and (ident? k) (namespace k)) "k must be namespaced keyword or resolvable symbol")
  (if (nil? spec)
    (swap! registry-ref dissoc k)
    (let [spec (if (c/or (spec? spec) (regex? spec) (get @registry-ref spec))
                 spec
                 (spec-impl form spec nil nil))]
      (swap! registry-ref assoc k (with-name spec k))))
  k)

(defn- ns-qualify
  "Qualify symbol s by resolving it or using the current *ns*."
  [s]
  (if-let [ns-sym (some-> s namespace symbol)]
    (c/or (some-> (get (ns-aliases *ns*) ns-sym) str (symbol (name s)))
          s)
    (symbol (str (ns-name *ns*)) (str s)))) ;; CLJW: (ns-name *ns*) instead of (.name *ns*)

(defmacro def
  "Given a namespace-qualified keyword or resolvable symbol k, and a
  spec, spec-name, predicate or regex-op makes an entry in the
  registry mapping k to the spec. Use nil to remove an entry in
  the registry for k."
  [k spec-form]
  (let [k (if (symbol? k) (ns-qualify k) k)]
    `(def-impl '~k '~(res spec-form) ~spec-form)))

(defn registry
  "returns the registry map, prefer 'get-spec' to lookup a spec by name"
  []
  @registry-ref)

(defn get-spec
  "Returns spec registered for keyword/symbol/var k, or nil."
  [k]
  (get (registry) (if (keyword? k) k (->sym k))))

(defmacro spec
  "Takes a single predicate form, e.g. can be the name of a predicate,
  like even?, or a fn literal like #(< % 42). Note that it is not
  generally necessary to wrap predicates in spec when using the rest
  of the spec macros, only to attach a unique generator

  Can also be passed the result of one of the regex ops -
  cat, alt, *, +, ?, in which case it will return a regex-conforming
  spec, useful when nesting an independent regex.
  ---

  Optionally takes :gen generator-fn, which must be a fn of no args that
  returns a test.check generator.

  Returns a spec."
  [form & {:keys [gen]}]
  (when form
    `(spec-impl '~(res form) ~form ~gen nil)))

;;--- dt / valid? / pvalid? (needed by spec-impl) ---

(defn- dt
  ([pred x form] (dt pred x form nil))
  ([pred x form cpred?]
   (if pred
     (if-let [spec (the-spec pred)]
       (conform spec x)
       (if (ifn? pred)
         (if cpred?
           (pred x)
           (if (pred x) x ::invalid))
         (throw (ex-info (str (pr-str form) " is not a fn, expected predicate fn") {:form form})))) ;; CLJW: ex-info
     x)))

(defn valid?
  "Helper function that returns true when x is valid for spec."
  ([spec x]
   (let [spec (specize spec)]
     (not (invalid? (conform* spec x)))))
  ([spec x form]
   (let [spec (specize spec form)]
     (not (invalid? (conform* spec x))))))

(defn- pvalid?
  "internal helper function that returns true when x is valid for spec."
  ([pred x]
   (not (invalid? (dt pred x ::unknown))))
  ([pred x form]
   (not (invalid? (dt pred x form)))))

;;--- spec-impl (the workhorse reify) ---

(defn spec-impl
  "Do not call this directly, use 'spec'"
  ([form pred gfn cpred?] (spec-impl form pred gfn cpred? nil))
  ([form pred gfn cpred? unc]
   (cond
     (spec? pred) (cond-> pred gfn (with-gen gfn))
     (regex? pred) (regex-spec-impl pred gfn)
     (ident? pred) (cond-> (the-spec pred) gfn (with-gen gfn))
     :else
     (reify
       Specize
       (specize* [s] s)
       (specize* [s _] s)

       Spec
       (conform* [_ x] (let [ret (pred x)]
                         (if cpred?
                           ret
                           (if ret x ::invalid))))
       (unform* [_ x] (if cpred?
                        (if unc
                          (unc x)
                          (throw (ex-info "no unform fn for conformer" {}))) ;; CLJW: ex-info
                        x))
       (explain* [_ path via in x]
         (when (invalid? (dt pred x form cpred?))
           [{:path path :pred form :val x :via via :in in}]))
       (gen* [_ _ _ _] (if gfn
                         (gfn)
                         (gen/gen-for-pred pred)))
       (with-gen* [_ gfn] (spec-impl form pred gfn cpred? unc))
       (describe* [_] form)))))

;;--- regex-spec-impl stub (full implementation in Phase 70.3) ---

;; CLJW: Minimal regex-spec-impl — wraps regex map into a Spec object.
;; Full regex ops (cat, alt, *, +, ?) will be implemented in Phase 70.3.
(defn regex-spec-impl
  "Do not call this directly, use the regex ops"
  [re gfn]
  (reify
    Specize
    (specize* [s] s)
    (specize* [s _] s)

    Spec
    (conform* [_ x]
     ;; CLJW: Placeholder — regex conform not yet implemented
      (throw (ex-info "regex spec conform not yet implemented (Phase 70.3)" {:re re})))
    (unform* [_ x]
      (throw (ex-info "regex spec unform not yet implemented (Phase 70.3)" {:re re})))
    (explain* [_ path via in x]
      (throw (ex-info "regex spec explain not yet implemented (Phase 70.3)" {:re re})))
    (gen* [_ _ _ _]
      (if gfn (gfn) nil))
    (with-gen* [_ gfn] (regex-spec-impl re gfn))
    (describe* [_]
      (if (::name re) (::name re) (::op re)))))

;;--- conformer (used in practice, small) ---

(defmacro conformer
  "Takes a predicate function with the semantics of conform i.e. it should return either a
  (possibly converted) value or :clojure.spec.alpha/invalid, and returns a
  spec that uses it as a predicate/conformer. Optionally takes a
  second fn that does unform of result of first"
  ([f] `(spec-impl '(conformer ~(res f)) ~f nil true))
  ([f unf] `(spec-impl '(conformer ~(res f) ~(res unf)) ~f nil true ~unf)))

;;--- nonconforming ---

(defn nonconforming
  "takes a spec and returns a spec that has the same properties except
  'conform' returns the original (not the conformed) value. Note, will specize regex ops."
  [spec]
  (let [spec (delay (specize spec))]
    (reify
      Specize
      (specize* [s] s)
      (specize* [s _] s)

      Spec
      (conform* [_ x] (let [ret (conform* @spec x)]
                        (if (invalid? ret)
                          ::invalid
                          x)))
      (unform* [_ x] x)
      (explain* [_ path via in x] (explain* @spec path via in x))
      (gen* [_ overrides path rmap] (gen* @spec overrides path rmap))
      (with-gen* [_ gfn] (nonconforming (with-gen* @spec gfn)))
      (describe* [_] `(nonconforming ~(describe* @spec))))))

;;--- helpers needed by spec impls ---

(defn- recur-limit? [rmap id path k]
  (c/and (> (get rmap id) (::recursion-limit rmap))
         (contains? (set path) k)))

(defn- inck [m k]
  (assoc m k (inc (c/or (get m k) 0))))

(defn- explain-1 [form pred path via in v]
  (let [pred (maybe-spec pred)]
    (if (spec? pred)
      (explain* pred path (if-let [name (spec-name pred)] (conj via name) via) in v)
      [{:path path :pred form :val v :via via :in in}])))

;; CLJW: tagged-ret — upstream uses clojure.lang.MapEntry constructor.
;; CW map entries are plain vectors, so use [tag ret].
;; UPSTREAM-DIFF: vector instead of MapEntry
(defn- tagged-ret [tag ret]
  [tag ret])

;;--- s/or ---

(defmacro or
  "Takes key+pred pairs, e.g.

  (s/or :even even? :small #(< % 42))

  Returns a destructuring spec that returns a map entry containing the
  key of the first matching pred and the corresponding value. Thus the
  'key' and 'val' functions can be used to refer generically to the
  components of the tagged return."
  [& key-pred-forms]
  (let [pairs (partition 2 key-pred-forms)
        keys (mapv first pairs)
        pred-forms (mapv second pairs)
        pf (mapv res pred-forms)]
    (c/assert (c/and (even? (count key-pred-forms)) (every? keyword? keys)) "spec/or expects k1 p1 k2 p2..., where ks are keywords")
    `(or-spec-impl ~keys '~pf ~pred-forms nil)))

(defn or-spec-impl
  "Do not call this directly, use 'or'"
  [keys forms preds gfn]
  (let [id (random-uuid) ;; CLJW: random-uuid instead of java.util.UUID/randomUUID
        kps (zipmap keys preds)
        specs (delay (mapv specize preds forms))
        cform (case (count preds)
                2 (fn [x]
                    (let [specs @specs
                          ret (conform* (specs 0) x)]
                      (if (invalid? ret)
                        (let [ret (conform* (specs 1) x)]
                          (if (invalid? ret)
                            ::invalid
                            (tagged-ret (keys 1) ret)))
                        (tagged-ret (keys 0) ret))))
                3 (fn [x]
                    (let [specs @specs
                          ret (conform* (specs 0) x)]
                      (if (invalid? ret)
                        (let [ret (conform* (specs 1) x)]
                          (if (invalid? ret)
                            (let [ret (conform* (specs 2) x)]
                              (if (invalid? ret)
                                ::invalid
                                (tagged-ret (keys 2) ret)))
                            (tagged-ret (keys 1) ret)))
                        (tagged-ret (keys 0) ret))))
                (fn [x]
                  (let [specs @specs]
                    (loop [i 0]
                      (if (< i (count specs))
                        (let [spec (specs i)]
                          (let [ret (conform* spec x)]
                            (if (invalid? ret)
                              (recur (inc i))
                              (tagged-ret (keys i) ret))))
                        ::invalid)))))]
    (reify
      Specize
      (specize* [s] s)
      (specize* [s _] s)

      Spec
      (conform* [_ x] (cform x))
      (unform* [_ [k x]] (unform (kps k) x))
      (explain* [this path via in x]
        (when-not (pvalid? this x)
          (apply concat
                 (map (fn [k form pred]
                        (when-not (pvalid? pred x)
                          (explain-1 form pred (conj path k) via in x)))
                      keys forms preds))))
      (gen* [_ overrides path rmap]
        (if gfn
          (gfn)
          (let [gen (fn [k p f]
                      (let [rmap (inck rmap id)]
                        (when-not (recur-limit? rmap id path k)
                          (gen/delay
                            (gensub p overrides (conj path k) rmap f)))))
                gs (remove nil? (map gen keys preds forms))]
            (when-not (empty? gs)
              (gen/one-of gs)))))
      (with-gen* [_ gfn] (or-spec-impl keys forms preds gfn))
      (describe* [_] `(or ~@(mapcat vector keys forms))))))

;;--- s/and ---

(defn- and-preds [x preds forms]
  (loop [ret x
         [pred & preds] preds
         [form & forms] forms]
    (if pred
      (let [nret (dt pred ret form)]
        (if (invalid? nret)
          ::invalid
          (recur nret preds forms)))
      ret)))

(defn- explain-pred-list
  [forms preds path via in x]
  (loop [ret x
         [form & forms] forms
         [pred & preds] preds]
    (when pred
      (let [nret (dt pred ret form)]
        (if (invalid? nret)
          (explain-1 form pred path via in ret)
          (recur nret forms preds))))))

(defmacro and
  "Takes predicate/spec-forms, e.g.

  (s/and even? #(< % 42))

  Returns a spec that returns the conformed value. Successive
  conformed values propagate through rest of predicates."
  [& pred-forms]
  `(and-spec-impl '~(mapv res pred-forms) ~(vec pred-forms) nil))

(defn and-spec-impl
  "Do not call this directly, use 'and'"
  [forms preds gfn]
  (let [specs (delay (mapv specize preds forms))
        cform
        (case (count preds)
          2 (fn [x]
              (let [specs @specs
                    ret (conform* (specs 0) x)]
                (if (invalid? ret)
                  ::invalid
                  (conform* (specs 1) ret))))
          3 (fn [x]
              (let [specs @specs
                    ret (conform* (specs 0) x)]
                (if (invalid? ret)
                  ::invalid
                  (let [ret (conform* (specs 1) ret)]
                    (if (invalid? ret)
                      ::invalid
                      (conform* (specs 2) ret))))))
          (fn [x]
            (let [specs @specs]
              (loop [ret x i 0]
                (if (< i (count specs))
                  (let [nret (conform* (specs i) ret)]
                    (if (invalid? nret)
                      ::invalid
                      (recur nret (inc i))))
                  ret)))))]
    (reify
      Specize
      (specize* [s] s)
      (specize* [s _] s)

      Spec
      (conform* [_ x] (cform x))
      (unform* [_ x] (reduce #(unform %2 %1) x (reverse preds)))
      (explain* [_ path via in x] (explain-pred-list forms preds path via in x))
      (gen* [_ overrides path rmap] (if gfn (gfn) (gensub (first preds) overrides path rmap (first forms))))
      (with-gen* [_ gfn] (and-spec-impl forms preds gfn))
      (describe* [_] `(and ~@forms)))))

;;--- s/merge ---

(defmacro merge
  "Takes map-validating specs (e.g. 'keys' specs) and
  returns a spec that returns a conformed map satisfying all of the
  specs.  Unlike 'and', merge can generate maps satisfying the
  union of the predicates."
  [& pred-forms]
  `(merge-spec-impl '~(mapv res pred-forms) ~(vec pred-forms) nil))

(defn merge-spec-impl
  "Do not call this directly, use 'merge'"
  [forms preds gfn]
  (reify
    Specize
    (specize* [s] s)
    (specize* [s _] s)

    Spec
    (conform* [_ x] (let [ms (map #(dt %1 x %2) preds forms)]
                      (if (some invalid? ms)
                        ::invalid
                        (apply c/merge ms))))
    (unform* [_ x] (apply c/merge (map #(unform % x) (reverse preds))))
    (explain* [_ path via in x]
      (apply concat
             (map #(explain-1 %1 %2 path via in x)
                  forms preds)))
    (gen* [_ overrides path rmap]
      (if gfn
        (gfn)
        (gen/fmap
         #(apply c/merge %)
         (apply gen/tuple (map #(gensub %1 overrides path rmap %2)
                               preds forms)))))
    (with-gen* [_ gfn] (merge-spec-impl forms preds gfn))
    (describe* [_] `(merge ~@forms))))

;;--- s/keys ---

(declare or-k-gen and-k-gen)

;; CLJW: k-gen, or-k-gen, and-k-gen — gen-related helpers for keys.
;; Stub: gen operations throw since test.check is unavailable.
(defn- k-gen [f]
  (cond
    (keyword? f) (gen/return [f])
    (c/and (seq? f) (#{`c/or `c/and} (first f)))
    (let [args (rest f)]
      (if (= (first f) `c/or)
        (gen/one-of (map k-gen args))
        (apply gen/tuple (map k-gen args))))
    :else (gen/return nil)))

(defn- or-k-gen [oks]
  (if (seq oks)
    (k-gen `(c/or ~@oks))
    (gen/return nil)))

(defn- and-k-gen [aks]
  (if (seq aks)
    (k-gen `(c/and ~@aks))
    (gen/return nil)))

(defmacro keys
  "Creates and returns a map validating spec. :req and :opt are both
  vectors of namespaced-qualified keywords. The validator will ensure
  the :req keys are present. The :opt keys serve as documentation and
  may be used by the generator.

  The :req key vector supports 'and' and 'or' for key groups:

  (s/keys :req [::x ::y (or ::secret (and ::user ::pwd))] :opt [::z])

  There are also -un versions of :req and :opt. These allow
  you to connect unqualified keys to specs.  In each case, fully
  qualified keywords are passed, which name the specs, but unqualified
  keys (with the same name component) are expected and checked at
  conform-time, and generated during gen:

  (s/keys :req-un [:my.ns/x :my.ns/y])

  The above says keys :x and :y are required, and will be validated
  and generated by specs (if they exist) named :my.ns/x :my.ns/y
  respectively.

  In addition, the values of *all* namespace-qualified keys will be validated
  (and possibly destructured) by any registered specs. Note: there is
  no support for inline value specification, by design.

  Optionally takes :gen generator-fn, which must be a fn of no args that
  returns a test.check generator."
  [& {:keys [req req-un opt opt-un gen]}]
  (let [unk #(-> % name keyword)
        req-keys (filterv keyword? (flatten req))
        req-un-specs (filterv keyword? (flatten req-un))
        _ (c/assert (every? #(c/and (keyword? %) (namespace %)) (concat req-keys req-un-specs opt opt-un))
                    "all keys must be namespace-qualified keywords")
        req-specs (into req-keys req-un-specs)
        req-keys (into req-keys (map unk req-un-specs))
        opt-keys (into (vec opt) (map unk opt-un))
        opt-specs (into (vec opt) opt-un)
        gx (gensym)
        parse-req (fn [rk f]
                    (map (fn [x]
                           (if (keyword? x)
                             `(contains? ~gx ~(f x))
                             (walk/postwalk
                              (fn [y] (if (keyword? y) `(contains? ~gx ~(f y)) y))
                              x)))
                         rk))
        pred-exprs [`(map? ~gx)]
        pred-exprs (into pred-exprs (parse-req req identity))
        pred-exprs (into pred-exprs (parse-req req-un unk))
        keys-pred `(fn* [~gx] (c/and ~@pred-exprs))
        pred-exprs (mapv (fn [e] `(fn* [~gx] ~e)) pred-exprs)
        pred-forms (walk/postwalk res pred-exprs)]
    `(map-spec-impl {:req '~req :opt '~opt :req-un '~req-un :opt-un '~opt-un
                     :req-keys '~req-keys :req-specs '~req-specs
                     :opt-keys '~opt-keys :opt-specs '~opt-specs
                     :pred-forms '~pred-forms
                     :pred-exprs ~pred-exprs
                     :keys-pred ~keys-pred
                     :gfn ~gen})))

(defn map-spec-impl
  "Do not call this directly, use 'keys'"
  [{:keys [req-un opt-un keys-pred pred-exprs opt-keys req-specs req req-keys opt-specs pred-forms opt gfn]
    :as argm}]
  (let [k->s (zipmap (concat req-keys opt-keys) (concat req-specs opt-specs))
        keys->specnames #(c/or (k->s %) %)
        id (random-uuid)] ;; CLJW: random-uuid
    (reify
      Specize
      (specize* [s] s)
      (specize* [s _] s)

      Spec
      (conform* [_ m]
        (if (keys-pred m)
          (let [reg (registry)]
            (loop [ret m, [[k v] & ks :as keys] m]
              (if keys
                (let [sname (keys->specnames k)]
                  (if-let [s (get reg sname)]
                    (let [cv (conform s v)]
                      (if (invalid? cv)
                        ::invalid
                        (recur (if (identical? cv v) ret (assoc ret k cv))
                               ks)))
                    (recur ret ks)))
                ret)))
          ::invalid))
      (unform* [_ m]
        (let [reg (registry)]
          (loop [ret m, [k & ks :as keys] (c/keys m)]
            (if keys
              (if (contains? reg (keys->specnames k))
                (let [cv (get m k)
                      v (unform (keys->specnames k) cv)]
                  (recur (if (identical? cv v) ret (assoc ret k v))
                         ks))
                (recur ret ks))
              ret))))
      (explain* [_ path via in x]
        (if-not (map? x)
          [{:path path :pred `map? :val x :via via :in in}]
          (let [reg (registry)]
            (apply concat
                   (when-let [probs (->> (map (fn [pred form] (when-not (pred x) form))
                                              pred-exprs pred-forms)
                                         (keep identity)
                                         seq)]
                     (map
                      #(identity {:path path :pred % :val x :via via :in in})
                      probs))
                   (map (fn [[k v]]
                          (when-not (c/or (not (contains? reg (keys->specnames k)))
                                          (pvalid? (keys->specnames k) v k))
                            (explain-1 (keys->specnames k) (keys->specnames k) (conj path k) via (conj in k) v)))
                        (seq x))))))
      (gen* [_ overrides path rmap]
        (if gfn
          (gfn)
          (let [rmap (inck rmap id)
                rgen (fn [k s] [k (gensub s overrides (conj path k) rmap k)])
                ogen (fn [k s]
                       (when-not (recur-limit? rmap id path k)
                         [k (gen/delay (gensub s overrides (conj path k) rmap k))]))
                reqs (map rgen req-keys req-specs)
                opts (remove nil? (map ogen opt-keys opt-specs))]
            (when (every? identity (concat (map second reqs) (map second opts)))
              (gen/bind
               (gen/tuple
                (and-k-gen req)
                (or-k-gen opt)
                (and-k-gen req-un)
                (or-k-gen opt-un))
               (fn [[req-ks opt-ks req-un-ks opt-un-ks]]
                 (let [qks (flatten (concat req-ks opt-ks))
                       unqks (map (comp keyword name) (flatten (concat req-un-ks opt-un-ks)))]
                   (->> (into reqs opts)
                        (filter #((set (concat qks unqks)) (first %)))
                        (apply concat)
                        (apply gen/hash-map)))))))))
      (with-gen* [_ gfn] (map-spec-impl (assoc argm :gfn gfn)))
      (describe* [_] (cons `keys
                           (cond-> []
                             req (conj :req req)
                             opt (conj :opt opt)
                             req-un (conj :req-un req-un)
                             opt-un (conj :opt-un opt-un)))))))

;;--- s/tuple ---

(defmacro tuple
  "takes one or more preds and returns a spec for a tuple, a vector
  where each element conforms to the corresponding pred. Each element
  will be referred to in paths using its ordinal."
  [& preds]
  (c/assert (not (empty? preds)))
  `(tuple-impl '~(mapv res preds) ~(vec preds)))

(defn tuple-impl
  "Do not call this directly, use 'tuple'"
  ([forms preds] (tuple-impl forms preds nil))
  ([forms preds gfn]
   (let [specs (delay (mapv specize preds forms))
         cnt (count preds)]
     (reify
       Specize
       (specize* [s] s)
       (specize* [s _] s)

       Spec
       (conform* [_ x]
         (let [specs @specs]
           (if-not (c/and (vector? x)
                          (= (count x) cnt))
             ::invalid
             (loop [ret x, i 0]
               (if (= i cnt)
                 ret
                 (let [v (x i)
                       cv (conform* (specs i) v)]
                   (if (invalid? cv)
                     ::invalid
                     (recur (if (identical? cv v) ret (assoc ret i cv))
                            (inc i)))))))))
       (unform* [_ x]
         (c/assert (c/and (vector? x)
                          (= (count x) (count preds))))
         (loop [ret x, i 0]
           (if (= i (count x))
             ret
             (let [cv (x i)
                   v (unform (preds i) cv)]
               (recur (if (identical? cv v) ret (assoc ret i v))
                      (inc i))))))
       (explain* [_ path via in x]
         (cond
           (not (vector? x))
           [{:path path :pred `vector? :val x :via via :in in}]

           (not= (count x) (count preds))
           [{:path path :pred `(= (count ~'%) ~(count preds)) :val x :via via :in in}]

           :else
           (apply concat
                  (map (fn [i form pred]
                         (let [v (x i)]
                           (when-not (pvalid? pred v)
                             (explain-1 form pred (conj path i) via (conj in i) v))))
                       (range (count preds)) forms preds))))
       (gen* [_ overrides path rmap]
         (if gfn
           (gfn)
           (let [gen (fn [i p f]
                       (gensub p overrides (conj path i) rmap f))
                 gs (map gen (range (count preds)) preds forms)]
             (when (every? identity gs)
               (apply gen/tuple gs)))))
       (with-gen* [_ gfn] (tuple-impl forms preds gfn))
       (describe* [_] `(tuple ~@forms))))))

;;--- s/nilable ---

(defn nilable-impl
  "Do not call this directly, use 'nilable'"
  [form pred gfn]
  (let [spec (delay (specize pred form))]
    (reify
      Specize
      (specize* [s] s)
      (specize* [s _] s)

      Spec
      (conform* [_ x] (if (nil? x) nil (conform* @spec x)))
      (unform* [_ x] (if (nil? x) nil (unform* @spec x)))
      (explain* [_ path via in x]
        (when-not (c/or (pvalid? @spec x) (nil? x))
          (conj
           (explain-1 form pred (conj path ::pred) via in x)
           {:path (conj path ::nil) :pred 'nil? :val x :via via :in in})))
      (gen* [_ overrides path rmap]
        (if gfn
          (gfn)
          (gen/frequency
           [[1 (gen/delay (gen/return nil))]
            [9 (gen/delay (gensub pred overrides (conj path ::pred) rmap form))]])))
      (with-gen* [_ gfn] (nilable-impl form pred gfn))
      (describe* [_] `(nilable ~(res form))))))

(defmacro nilable
  "returns a spec that accepts nil and values satisfying pred"
  [pred]
  (let [pf (res pred)]
    `(nilable-impl '~pf ~pred nil)))

;;--- s/every, s/coll-of, s/every-kv, s/map-of ---

(defn- res-kind
  [opts]
  (let [{kind :kind :as mopts} opts]
    (->>
     (if kind
       (assoc mopts :kind `~(res kind))
       mopts)
     (mapcat identity))))

(defn- coll-prob [x kfn kform distinct count min-count max-count
                  path via in]
  (let [pred (c/or kfn coll?)
        kform (c/or kform `coll?)]
    (cond
      (not (pvalid? pred x))
      (explain-1 kform pred path via in x)

      (c/and count (not= count (bounded-count count x)))
      [{:path path :pred `(= ~count (c/count ~'%)) :val x :via via :in in}]

      ;; CLJW: Long/MAX_VALUE instead of Integer/MAX_VALUE
      (c/and (c/or min-count max-count)
             (not (<= (c/or min-count 0)
                      (bounded-count (if max-count (inc max-count) min-count) x)
                      (c/or max-count Long/MAX_VALUE))))
      [{:path path :pred `(<= ~(c/or min-count 0) (c/count ~'%) ~(c/or max-count 'Long/MAX_VALUE)) :val x :via via :in in}]

      (c/and distinct (not (empty? x)) (not (apply distinct? x)))
      [{:path path :pred 'distinct? :val x :via via :in in}])))

(def ^:private empty-coll {`vector? [], `set? #{}, `list? (), `map? {}})

(defn every-impl
  "Do not call this directly, use 'every', 'every-kv', 'coll-of' or 'map-of'"
  ([form pred opts] (every-impl form pred opts nil))
  ([form pred {conform-into :into
               describe-form ::describe
               :keys [kind ::kind-form count max-count min-count distinct gen-max ::kfn ::cpred
                      conform-keys ::conform-all]
               :or {gen-max 20}
               :as opts}
    gfn]
   (let [gen-into (if conform-into (empty conform-into) (get empty-coll kind-form))
         spec (delay (specize pred))
         check? #(valid? @spec %)
         kfn (c/or kfn (fn [i v] i))
         addcv (fn [ret i v cv] (conj ret cv))
         cfns (fn [x]
                (cond
                  (c/and (vector? x) (c/or (not conform-into) (vector? conform-into)))
                  [identity
                   (fn [ret i v cv]
                     (if (identical? v cv)
                       ret
                       (assoc ret i cv)))
                   identity]

                  (c/and (map? x) (c/or (c/and kind (not conform-into)) (map? conform-into)))
                  [(if conform-keys empty identity)
                   (fn [ret i v cv]
                     (if (c/and (identical? v cv) (not conform-keys))
                       ret
                       (assoc ret (nth (if conform-keys cv v) 0) (nth cv 1))))
                   identity]

                  (c/or (list? conform-into) (seq? conform-into) (c/and (not conform-into) (c/or (list? x) (seq? x))))
                  [(constantly ()) addcv reverse]

                  :else [#(empty (c/or conform-into %)) addcv identity]))]
     (reify
       Specize
       (specize* [s] s)
       (specize* [s _] s)

       Spec
       (conform* [_ x]
         (let [spec @spec]
           (cond
             (not (cpred x)) ::invalid

             conform-all
             (let [[init add complete] (cfns x)]
               (loop [ret (init x), i 0, [v & vs :as vseq] (seq x)]
                 (if vseq
                   (let [cv (conform* spec v)]
                     (if (invalid? cv)
                       ::invalid
                       (recur (add ret i v cv) (inc i) vs)))
                   (complete ret))))

             :else
             (if (indexed? x)
               (let [step (max 1 (long (/ (c/count x) *coll-check-limit*)))]
                 (loop [i 0]
                   (if (>= i (c/count x))
                     x
                     (if (valid? spec (nth x i))
                       (recur (c/+ i step))
                       ::invalid))))
               (let [limit *coll-check-limit*]
                 (loop [i 0 [v & vs :as vseq] (seq x)]
                   (cond
                     (c/or (nil? vseq) (= i limit)) x
                     (valid? spec v) (recur (inc i) vs)
                     :else ::invalid)))))))
       (unform* [_ x]
         (if conform-all
           (let [spec @spec
                 [init add complete] (cfns x)]
             (loop [ret (init x), i 0, [v & vs :as vseq] (seq x)]
               (if (>= i (c/count x))
                 (complete ret)
                 (recur (add ret i v (unform* spec v)) (inc i) vs))))
           x))
       (explain* [_ path via in x]
         (c/or (coll-prob x kind kind-form distinct count min-count max-count
                          path via in)
               (apply concat
                      ((if conform-all identity (partial take *coll-error-limit*))
                       (keep identity
                             (map (fn [i v]
                                    (let [k (kfn i v)]
                                      (when-not (check? v)
                                        (let [prob (explain-1 form pred path via (conj in k) v)]
                                          prob))))
                                  (range) x))))))
       (gen* [_ overrides path rmap]
         (if gfn
           (gfn)
           (let [pgen (gensub pred overrides path rmap form)]
             (gen/bind
              (cond
                gen-into (gen/return gen-into)
                kind (gen/fmap #(if (empty? %) % (empty %))
                               (gensub kind overrides path rmap form))
                :else (gen/return []))
              (fn [init]
                (gen/fmap
                 #(if (vector? init) % (into init %))
                 (cond
                   distinct
                   (if count
                     (gen/vector-distinct pgen {:num-elements count :max-tries 100})
                     (gen/vector-distinct pgen {:min-elements (c/or min-count 0)
                                                :max-elements (c/or max-count (max gen-max (c/* 2 (c/or min-count 0))))
                                                :max-tries 100}))

                   count
                   (gen/vector pgen count)

                   (c/or min-count max-count)
                   (gen/vector pgen (c/or min-count 0) (c/or max-count (max gen-max (c/* 2 (c/or min-count 0)))))

                   :else
                   (gen/vector pgen 0 gen-max))))))))

       (with-gen* [_ gfn] (every-impl form pred opts gfn))
       (describe* [_] (c/or describe-form `(every ~(res form) ~@(mapcat identity opts))))))))

(defmacro every
  "takes a pred and validates collection elements against that pred.

  Note that 'every' does not do exhaustive checking, rather it samples
  *coll-check-limit* elements. Nor (as a result) does it do any
  conforming of elements. 'explain' will report at most *coll-error-limit*
  problems.  Thus 'every' should be suitable for potentially large
  collections.

  Takes several kwargs options that further constrain the collection:

  :kind - a pred that the collection type must satisfy, e.g. vector?
        (default nil) Note that if :kind is specified and :into is
        not, this pred must generate in order for every to generate.
  :count - specifies coll has exactly this count (default nil)
  :min-count, :max-count - coll has count (<= min-count count max-count) (defaults nil)
  :distinct - all the elements are distinct (default nil)

  And additional args that control gen

  :gen-max - the maximum coll size to generate (default 20)
  :into - one of [], (), {}, #{} - the default collection to generate into
      (default: empty coll as generated by :kind pred if supplied, else [])

  Optionally takes :gen generator-fn, which must be a fn of no args that
  returns a test.check generator

  See also - coll-of, every-kv"
  [pred & {:keys [into kind count max-count min-count distinct gen-max gen] :as opts}]
  (let [desc (::describe opts)
        nopts (-> opts
                  (dissoc :gen ::describe)
                  (assoc ::kind-form `'~(res (:kind opts))
                         ::describe (c/or desc `'(every ~(res pred) ~@(res-kind opts)))))
        gx (gensym)
        ;; CLJW: Long/MAX_VALUE instead of Integer/MAX_VALUE
        cpreds (cond-> [(list (c/or kind `coll?) gx)]
                 count (conj `(= ~count (bounded-count ~count ~gx)))

                 (c/or min-count max-count)
                 (conj `(<= (c/or ~min-count 0)
                            (bounded-count (if ~max-count (inc ~max-count) ~min-count) ~gx)
                            (c/or ~max-count Long/MAX_VALUE)))

                 distinct
                 (conj `(c/or (empty? ~gx) (apply distinct? ~gx))))]
    `(every-impl '~pred ~pred ~(assoc nopts ::cpred `(fn* [~gx] (c/and ~@cpreds))) ~gen)))

(defmacro every-kv
  "like 'every' but takes separate key and val preds and works on associative collections.

  Same options as 'every', :into defaults to {}

  See also - map-of"
  [kpred vpred & opts]
  (let [desc `(every-kv ~(res kpred) ~(res vpred) ~@(res-kind opts))]
    `(every (tuple ~kpred ~vpred) ::kfn (fn [i# v#] (nth v# 0)) :into {} ::describe '~desc ~@opts)))

(defmacro coll-of
  "Returns a spec for a collection of items satisfying pred. Unlike
  'every', coll-of will exhaustively conform every value.

  Same options as 'every'. conform will produce a collection
  corresponding to :into if supplied, else will match the input collection,
  avoiding rebuilding when possible.

  See also - every, map-of"
  [pred & opts]
  (let [desc `(coll-of ~(res pred) ~@(res-kind opts))]
    `(every ~pred ::conform-all true ::describe '~desc ~@opts)))

(defmacro map-of
  "Returns a spec for a map whose keys satisfy kpred and vals satisfy
  vpred. Unlike 'every-kv', map-of will exhaustively conform every
  value.

  Same options as 'every', :kind defaults to map?, with the addition of:

  :conform-keys - conform keys as well as values (default false)

  See also - every-kv"
  [kpred vpred & opts]
  (let [desc `(map-of ~(res kpred) ~(res vpred) ~@(res-kind opts))]
    `(every-kv ~kpred ~vpred ::conform-all true :kind map? ::describe '~desc ~@opts)))
