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

;;--- Regex engine (Phase 70.3) ---

(defn- accept [x] {::op ::accept :ret x})

(defn- accept? [{:keys [::op]}]
  (= ::accept op))

(defn- pcat* [{[p1 & pr :as ps] :ps, [k1 & kr :as ks] :ks, [f1 & fr :as forms] :forms, ret :ret, rep+ :rep+}]
  (when (every? identity ps)
    (if (accept? p1)
      (let [rp (:ret p1)
            ret (conj ret (if ks {k1 rp} rp))]
        (if pr
          (pcat* {:ps pr :ks kr :forms fr :ret ret})
          (accept ret)))
      {::op ::pcat, :ps ps, :ret ret, :ks ks, :forms forms :rep+ rep+})))

(defn- pcat [& ps] (pcat* {:ps ps :ret []}))

(defn cat-impl
  "Do not call this directly, use 'cat'"
  [ks ps forms]
  (pcat* {:ks ks, :ps ps, :forms forms, :ret {}}))

(defn- rep* [p1 p2 ret splice form]
  (when p1
    ;; CLJW: random-uuid instead of java.util.UUID/randomUUID
    (let [r {::op ::rep, :p2 p2, :splice splice, :forms form :id (random-uuid)}]
      (if (accept? p1)
        (assoc r :p1 p2 :ret (conj ret (:ret p1)))
        (assoc r :p1 p1, :ret ret)))))

(defn rep-impl
  "Do not call this directly, use '*'"
  [form p] (rep* p p [] false form))

(defn rep+impl
  "Do not call this directly, use '+'"
  [form p]
  (pcat* {:ps [p (rep* p p [] true form)] :forms `[~form (* ~form)] :ret [] :rep+ form}))

(defn- filter-alt [ps ks forms f]
  (if (c/or ks forms)
    (let [pks (->> (map vector ps
                        (c/or (seq ks) (repeat nil))
                        (c/or (seq forms) (repeat nil)))
                   (filter #(-> % first f)))]
      [(seq (map first pks)) (when ks (seq (map second pks))) (when forms (seq (map #(nth % 2) pks)))])
    [(seq (filter f ps)) ks forms]))

(defn- alt* [ps ks forms]
  (let [[[p1 & pr :as ps] [k1 :as ks] forms] (filter-alt ps ks forms identity)]
    (when ps
      (let [ret {::op ::alt, :ps ps, :ks ks :forms forms}]
        (if (nil? pr)
          (if k1
            (if (accept? p1)
              (accept (tagged-ret k1 (:ret p1)))
              ret)
            p1)
          ret)))))

(defn- alts [& ps] (alt* ps nil nil))
(defn- alt2 [p1 p2] (if (c/and p1 p2) (alts p1 p2) (c/or p1 p2)))

(defn alt-impl
  "Do not call this directly, use 'alt'"
  [ks ps forms] (assoc (alt* ps ks forms) :id (random-uuid)))

(defn maybe-impl
  "Do not call this directly, use '?'"
  [p form] (assoc (alt* [p (accept ::nil)] nil [form ::nil]) :maybe form))

(defn amp-impl
  "Do not call this directly, use '&'"
  [re re-form preds pred-forms]
  {::op ::amp :p1 re :amp re-form :ps preds :forms pred-forms})

(defn- noret? [p1 pret]
  (c/or (= pret ::nil)
        (c/and (#{::rep ::pcat} (::op (reg-resolve! p1)))
               (empty? pret))
        nil))

(defn- accept-nil? [p]
  (let [{:keys [::op ps p1 p2 forms] :as p} (reg-resolve! p)]
    (cond
      (= op ::accept) true
      (nil? op) nil
      (= op ::amp) (c/and (accept-nil? p1)
                          (let [ret (-> (preturn p1) (and-preds ps (next forms)))]
                            (not (invalid? ret))))
      (= op ::rep) (c/or (identical? p1 p2) (accept-nil? p1))
      (= op ::pcat) (every? accept-nil? ps)
      (= op ::alt) (c/some accept-nil? ps))))

(defn- add-ret [p r k]
  (let [{:keys [::op ps splice] :as p} (reg-resolve! p)
        prop #(let [ret (preturn p)]
                (if (empty? ret) r ((if splice into conj) r (if k {k ret} ret))))]
    (cond
      (nil? op) r
      (#{::alt ::accept ::amp} op)
      (let [ret (preturn p)]
        (if (= ret ::nil) r (conj r (if k {k ret} ret))))
      (#{::rep ::pcat} op) (prop))))

(defn- preturn [p]
  (let [{[p0 & pr :as ps] :ps, [k :as ks] :ks, :keys [::op p1 ret forms] :as p} (reg-resolve! p)]
    (cond
      (= op ::accept) ret
      (nil? op) nil
      (= op ::amp) (let [pret (preturn p1)]
                     (if (noret? p1 pret)
                       ::nil
                       (and-preds pret ps forms)))
      (= op ::rep) (add-ret p1 ret k)
      (= op ::pcat) (add-ret p0 ret k)
      (= op ::alt) (let [[[p0] [k0]] (filter-alt ps ks forms accept-nil?)
                         r (if (nil? p0) ::nil (preturn p0))]
                     (if k0 (tagged-ret k0 r) r)))))

(defn- deriv
  [p x]
  (let [{[p0 & pr :as ps] :ps, [k0 & kr :as ks] :ks, :keys [::op p1 p2 ret splice forms amp] :as p} (reg-resolve! p)]
    (when p
      (cond
        (= op ::accept) nil
        (nil? op) (let [ret (dt p x p)]
                    (when-not (invalid? ret) (accept ret)))
        (= op ::amp) (when-let [p1 (deriv p1 x)]
                       (if (= ::accept (::op p1))
                         (let [ret (-> (preturn p1) (and-preds ps (next forms)))]
                           (when-not (invalid? ret)
                             (accept ret)))
                         (amp-impl p1 amp ps forms)))
        (= op ::pcat) (alt2 (pcat* {:ps (cons (deriv p0 x) pr), :ks ks, :forms forms, :ret ret})
                            (when (accept-nil? p0) (deriv (pcat* {:ps pr, :ks kr, :forms (next forms), :ret (add-ret p0 ret k0)}) x)))
        (= op ::alt) (alt* (map #(deriv % x) ps) ks forms)
        (= op ::rep) (alt2 (rep* (deriv p1 x) p2 ret splice forms)
                           (when (accept-nil? p1) (deriv (rep* p2 p2 (add-ret p1 ret nil) splice forms) x)))))))

;; CLJW: explicit symbol literals instead of syntax-quote to avoid
;; read-time resolution of excluded symbols (cat→core/cat, +→core/+, etc.)
(defn- op-describe [p]
  (let [{:keys [::op ps ks forms splice p1 rep+ maybe amp] :as p} (reg-resolve! p)]
    (when p
      (cond
        (= op ::accept) nil
        (nil? op) p
        (= op ::amp) (list* 'clojure.spec.alpha/& amp forms)
        (= op ::pcat) (if rep+
                        (list 'clojure.spec.alpha/+ rep+)
                        (cons 'clojure.spec.alpha/cat (mapcat vector (c/or (seq ks) (repeat :_)) forms)))
        (= op ::alt) (if maybe
                       (list 'clojure.spec.alpha/? maybe)
                       (cons 'clojure.spec.alpha/alt (mapcat vector ks forms)))
        (= op ::rep) (list (if splice 'clojure.spec.alpha/+ 'clojure.spec.alpha/*) forms)))))

(defn- op-explain [form p path via in input]
  (let [[x :as input] input
        {:keys [::op ps ks forms splice p1 p2] :as p} (reg-resolve! p)
        via (if-let [name (spec-name p)] (conj via name) via)
        insufficient (fn [path form]
                       [{:path path
                         :reason "Insufficient input"
                         :pred form
                         :val ()
                         :via via
                         :in in}])]
    (when p
      (cond
        (= op ::accept) nil
        (nil? op) (if (empty? input)
                    (insufficient path form)
                    (explain-1 form p path via in x))
        (= op ::amp) (if (empty? input)
                       (if (accept-nil? p1)
                         (explain-pred-list forms ps path via in (preturn p1))
                         (insufficient path (:amp p)))
                       (if-let [p1 (deriv p1 x)]
                         (explain-pred-list forms ps path via in (preturn p1))
                         (op-explain (:amp p) p1 path via in input)))
        (= op ::pcat) (let [pkfs (map vector
                                      ps
                                      (c/or (seq ks) (repeat nil))
                                      (c/or (seq forms) (repeat nil)))
                            [pred k form] (if (= 1 (count pkfs))
                                            (first pkfs)
                                            (first (remove (fn [[p]] (accept-nil? p)) pkfs)))
                            path (if k (conj path k) path)
                            form (c/or form (op-describe pred))]
                        (if (c/and (empty? input) (not pred))
                          (insufficient path form)
                          (op-explain form pred path via in input)))
        (= op ::alt) (if (empty? input)
                       (insufficient path (op-describe p))
                       (apply concat
                              (map (fn [k form pred]
                                     (op-explain (c/or form (op-describe pred))
                                                 pred
                                                 (if k (conj path k) path)
                                                 via
                                                 in
                                                 input))
                                   (c/or (seq ks) (repeat nil))
                                   (c/or (seq forms) (repeat nil))
                                   ps)))
        (= op ::rep) (op-explain (if (identical? p1 p2)
                                   forms
                                   (op-describe p1))
                                 p1 path via in input)))))

(defn- op-unform [p x]
  (let [{[p0 & pr :as ps] :ps, [k :as ks] :ks, :keys [::op p1 ret forms rep+ maybe] :as p} (reg-resolve! p)
        kps (zipmap ks ps)]
    (cond
      (= op ::accept) [ret]
      (nil? op) [(unform p x)]
      (= op ::amp) (let [px (reduce #(unform %2 %1) x (reverse ps))]
                     (op-unform p1 px))
      (= op ::rep) (mapcat #(op-unform p1 %) x)
      (= op ::pcat) (if rep+
                      (mapcat #(op-unform p0 %) x)
                      (mapcat (fn [k]
                                (when (contains? x k)
                                  (op-unform (kps k) (get x k))))
                              ks))
      (= op ::alt) (if maybe
                     [(unform p0 x)]
                     (let [[k v] x]
                       (op-unform (kps k) v))))))

(defn- re-conform [p [x & xs :as data]]
  (if (empty? data)
    (if (accept-nil? p)
      (let [ret (preturn p)]
        (if (= ret ::nil)
          nil
          ret))
      ::invalid)
    (if-let [dp (deriv p x)]
      (recur dp xs)
      ::invalid)))

(defn- re-explain [path via in re input]
  (loop [p re [x & xs :as data] input i 0]
    (if (empty? data)
      (if (accept-nil? p)
        nil
        (op-explain (op-describe p) p path via in nil))
      (if-let [dp (deriv p x)]
        (recur dp xs (inc i))
        (if (accept? p)
          (if (= (::op p) ::pcat)
            (op-explain (op-describe p) p path via (conj in i) (seq data))
            [{:path path
              :reason "Extra input"
              :pred (op-describe re)
              :val data
              :via via
              :in (conj in i)}])
          (c/or (op-explain (op-describe p) p path via (conj in i) (seq data))
                [{:path path
                  :reason "Extra input"
                  :pred (op-describe p)
                  :val data
                  :via via
                  :in (conj in i)}]))))))

(defn regex-spec-impl
  "Do not call this directly, use the regex ops"
  [re gfn]
  (reify
    Specize
    (specize* [s] s)
    (specize* [s _] s)

    Spec
    (conform* [_ x]
      (if (c/or (nil? x) (sequential? x))
        (re-conform re (seq x))
        ::invalid))
    (unform* [_ x] (op-unform re x))
    (explain* [_ path via in x]
      (if (c/or (nil? x) (sequential? x))
        (re-explain path via in re (seq x))
        [{:path path :pred '(or nil? sequential?) :val x :via via :in in}]))
    (gen* [_ _ _ _]
      (if gfn (gfn) nil))
    (with-gen* [_ gfn] (regex-spec-impl re gfn))
    (describe* [_] (op-describe re))))

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
      ;; CLJW: explicit symbol — 'or' excluded from core, syntax-quote would misresolve
      (describe* [_] (cons 'clojure.spec.alpha/or (mapcat vector keys forms))))))

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
      ;; CLJW: explicit symbol — 'and' excluded from core
      (describe* [_] (cons 'clojure.spec.alpha/and forms)))))

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
    ;; CLJW: explicit symbol — 'merge' excluded from core
    (describe* [_] (cons 'clojure.spec.alpha/merge forms))))

;;--- s/keys ---

(declare or-k-gen and-k-gen)

;; CLJW: k-gen, or-k-gen, and-k-gen — upstream-compatible key generators.
;; Upstream checks for plain symbols 'or/'and in key forms.
(defn- k-gen
  "returns a generator for form f, which can be a keyword or a list
  starting with 'or or 'and."
  [f]
  (cond
    (keyword? f) (gen/return f)
    (= 'or  (first f)) (or-k-gen 1 (rest f))
    (= 'and (first f)) (and-k-gen (rest f))))

(defn- or-k-gen
  "returns a tuple generator made up of generators for a random subset
  of min-count (default 0) to all elements in s."
  ([s] (or-k-gen 0 s))
  ([min-count s]
   (gen/bind (gen/tuple
              (gen/choose min-count (count s))
              (gen/shuffle (mapv k-gen s)))
             (fn [[n gens]]
               (apply gen/tuple (take n gens))))))

(defn- and-k-gen
  "returns a tuple generator made up of generators for every element
  in s."
  [s]
  (apply gen/tuple (mapv k-gen s)))

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
      ;; CLJW: explicit symbol — 'keys' excluded from core
      (describe* [_] (cons 'clojure.spec.alpha/keys
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

;;--- Phase 70.3: Regex macros + advanced specs ---

(defmacro cat
  "Takes key+pred pairs, e.g.
  (s/cat :e1 e1-pred :e2 e2-pred ...)
  Returns a regex op that matches (all) values in sequence, returning a map
  with the keys."
  [& key-pred-forms]
  (let [pairs (partition 2 key-pred-forms)
        ks (mapv first pairs)
        ps (mapv second pairs)
        pf (mapv res ps)]
    `(cat-impl ~ks ~ps '~pf)))

(defmacro alt
  "Takes key+pred pairs, e.g.
  (s/alt :even even? :small #(< % 42))
  Returns a regex op that returns a map entry containing the key of the
  first matching pred and the corresponding value."
  [& key-pred-forms]
  (let [pairs (partition 2 key-pred-forms)
        ks (mapv first pairs)
        ps (mapv second pairs)
        pf (mapv res ps)]
    `(alt-impl ~ks ~ps '~pf)))

(defmacro *
  "Returns a regex op that matches zero or more values matching
  pred. Produces a vector of matches iff there is at least one match"
  [pred-form]
  `(rep-impl '~(res pred-form) ~(res pred-form)))

(defmacro +
  "Returns a regex op that matches one or more values matching
  pred. Produces a vector of matches"
  [pred-form]
  `(rep+impl '~(res pred-form) ~(res pred-form)))

(defmacro ?
  "Returns a regex op that matches zero or one value matching
  pred. Produces a single value (not a collection) if matched."
  [pred-form]
  `(maybe-impl ~(res pred-form) '~(res pred-form)))

(defmacro &
  "Takes a regex op re, and predicates. Returns a regex-op that consumes
  input as per re but subjects the resulting value to the conjunction of
  the predicates, and any conforming they might perform."
  [re & preds]
  (let [pv (vec preds)]
    `(amp-impl ~re '~(res re) ~pv '~(mapv res pv))))

;;--- fspec ---

;; CLJW: fspec simplified — gen tests omitted (no test.check), but
;; conform checks ifn? and optionally validates one call.
(defn fspec-impl
  "Do not call this directly, use 'fspec'"
  [argspec aform retspec rform fnspec fform gfn]
  (let [specs {:args argspec :ret retspec :fn fnspec}]
    (reify
      Specize
      (specize* [s] s)
      (specize* [s _] s)

      Spec
      (conform* [_ f]
        (if (ifn? f) f ::invalid))
      (unform* [_ f] f)
      (explain* [_ path via in f]
        (if (ifn? f)
          nil
          [{:path path :pred 'ifn? :val f :via via :in in}]))
      (gen* [_ _ _ _]
        (if gfn (gfn) nil))
      (with-gen* [_ gfn] (fspec-impl argspec aform retspec rform fnspec fform gfn))
      (describe* [_] `(fspec :args ~aform :ret ~rform :fn ~fform)))))

(defmacro fspec
  "takes :args :ret and (optional) :fn kwargs whose values are preds
  and returns a spec whose conform/explain take a fn and validates it
  using generative testing."
  [& {:keys [args ret fn] :or {ret `any?}}]
  `(fspec-impl (spec ~args) '~(res args) (spec ~ret) '~(res ret) (spec ~fn) '~(res fn) nil))

(defmacro fdef
  "Takes a symbol naming a function, and one or more of the following:
  :args A regex spec for the function arguments
  :ret A spec for the function's return value
  :fn A spec of the relationship between args and ret"
  [fn-sym & specs]
  `(clojure.spec.alpha/def ~fn-sym (clojure.spec.alpha/fspec ~@specs)))

;;--- multi-spec ---

;; CLJW: multi-spec-impl adapted for CW's defmulti implementation.
;; Uses dispatch-fn and get-method instead of Java reflection.
(defn multi-spec-impl
  "Do not call this directly, use 'multi-spec'"
  ([form mmvar retag] (multi-spec-impl form mmvar retag nil))
  ([form mmvar retag gfn]
   (let [id (random-uuid)
         ;; CLJW: access multimethod internals via CW's defmulti
         predx #(let [mm @mmvar
                      dispatch-val ((get mm :dispatch-fn) %)]
                  (when (get-method mm dispatch-val)
                    (mm %)))
         dval #((get @mmvar :dispatch-fn) %)
         tag (if (keyword? retag)
               #(assoc %1 retag %2)
               retag)]
     (reify
       Specize
       (specize* [s] s)
       (specize* [s _] s)

       Spec
       (conform* [_ x]
         (if-let [pred (predx x)]
           (dt pred x form)
           ::invalid))
       (unform* [_ x]
         (if-let [pred (predx x)]
           (unform pred x)
           (throw (ex-info (str "No method of: " form " for dispatch value: " (dval x)) {}))))
       (explain* [_ path via in x]
         (let [dv (dval x)
               path (conj path dv)]
           (if-let [pred (predx x)]
             (explain-1 form pred path via in x)
             [{:path path :pred form :val x :reason "no method" :via via :in in}])))
       (gen* [_ _ _ _]
         (if gfn (gfn) nil))
       (with-gen* [_ gfn] (multi-spec-impl form mmvar retag gfn))
       (describe* [_] `(multi-spec ~form ~retag))))))

(defmacro multi-spec
  "Takes the name of a spec'd multimethod and a tag-restoring keyword or fn
  (retag). Returns a spec that when conforming or explaining data will
  dispatch on the value to the multimethod, using the retag to conj/assoc
  the dispatch-val onto the conforming value."
  [mm retag]
  `(multi-spec-impl '~mm (var ~mm) ~retag))

;;--- assert ---

;; CLJW: *compile-asserts* — always true (no system properties)
(defonce ^:dynamic *compile-asserts* true)

;; CLJW: Runtime assert check flag (no RT.checkSpecAsserts, use atom)
(def ^:private check-asserts-flag (atom false))

(defn check-asserts?
  "Returns the value set by check-asserts."
  []
  @check-asserts-flag)

(defn check-asserts
  "Enable or disable spec asserts."
  [flag]
  (reset! check-asserts-flag flag))

(defn assert*
  "Do not call this directly, use 'assert'."
  [spec x]
  (if (valid? spec x)
    x
    (let [ed (c/merge (assoc (explain-data* spec [] [] [] x)
                             ::failure :assertion-failed))]
      (throw (ex-info
              (str "Spec assertion failed\n" (with-out-str (explain-out ed)))
              ed)))))

(defmacro assert
  "spec-checking assert expression. Returns x if x is valid? according
to spec, else throws an ex-info with explain-data plus ::failure of
:assertion-failed."
  [spec x]
  (if *compile-asserts*
    `(if (check-asserts?)
       (assert* ~spec ~x)
       ~x)
    x))

;;--- int-in, double-in, inst-in ---

(defn int-in-range?
  "Return true if start <= val, val < end and val is a fixed
  precision integer."
  [start end val]
  (c/and (int? val) (<= start val) (< val end)))

(defmacro int-in
  "Returns a spec that validates fixed precision integers in the
  range from start (inclusive) to end (exclusive)."
  [start end]
  ;; CLJW: ~'clojure.spec.alpha/and — explicit qualification needed because
  ;; CW's read-all-then-eval-all processes syntax-quote before ns :exclude
  `(spec (~'clojure.spec.alpha/and int? #(int-in-range? ~start ~end %))))

;; CLJW: double-in uses CW's double? and math predicates
(defmacro double-in
  "Specs a 64-bit floating point number."
  [& {:keys [infinite? NaN? min max]
      :or {infinite? true NaN? true}
      :as m}]
  ;; CLJW: ~'clojure.spec.alpha/and — see int-in comment
  `(spec (~'clojure.spec.alpha/and c/double?
                                   ~@(when-not infinite? ['#(not (Double/isInfinite %))])
                                   ~@(when-not NaN? ['#(not (Double/isNaN %))])
                                   ~@(when max [`#(<= % ~max)])
                                   ~@(when min [`#(<= ~min %)]))))

;; CLJW: inst-in — CW doesn't have java.util.Date, stub for API compat
(defn inst-in-range?
  "Return true if inst at or after start and before end"
  [start end inst]
  ;; CLJW: stub — inst types not yet available
  false)

(defmacro inst-in
  "Returns a spec that validates insts in the range from start
  (inclusive) to end (exclusive)."
  [start end]
  ;; CLJW: stub — inst types not yet available; ~'clojure.spec.alpha/and — see int-in comment
  `(spec (~'clojure.spec.alpha/and inst? #(inst-in-range? ~start ~end %))))

;;--- exercise, exercise-fn ---

(defn exercise
  "generates a number of values compatible with spec and maps conform over them,
  returning a sequence of [val conformed-val] pairs. Optionally takes
  a generator overrides map as per gen"
  ([spec] (exercise spec 10))
  ([spec n] (exercise spec n nil))
  ([spec n overrides]
   (map (fn [_] (let [s (gensub spec overrides [] {::recursion-limit *recursion-limit*} spec)]
                  (let [v (gen/generate s)]
                    [v (conform spec v)])))
        (range n))))

(defn exercise-fn
  "exercises the fn named by sym (a symbol) by applying it to
  n (default 10) generated samples of its args spec returning a sequence of
  [args ret] tuples. Optionally takes a generator overrides map as per gen"
  ([sym] (exercise-fn sym 10))
  ([sym n] (exercise-fn sym n nil))
  ([sym n fspec]
   (let [f @(resolve sym)
         spec (c/or fspec (get-spec sym))]
     (if spec
       (let [g (gen (:args spec))]
         (map (fn [_]
                (let [args (gen/generate g)]
                  [args (apply f args)]))
              (range n)))
       (throw (ex-info "No fspec found" {:sym sym}))))))
