;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; CLJW: Lightweight generator implementation for spec.alpha exercise/exercise-fn.
;; No rose tree or shrinking — size-based generation using CW's built-in PRNG.
;; Generator representation: {:cljw/gen true :gen (fn [size] value)}

(ns clojure.spec.gen.alpha
  (:refer-clojure :exclude [boolean bytes cat delay hash-map list map not-empty set shuffle vector]))

;;--- Layer 0: Foundation ---

;; CLJW: must use clojure.core/array-map explicitly — this ns excludes hash-map
;; from clojure.core, and CW's compiler emits hash-map calls for map literals
;; with runtime values, causing infinite recursion.
(defn- make-gen [gen-fn]
  (clojure.core/array-map :cljw/gen true :gen gen-fn))

(defn generator? [x]
  (and (map? x) (:cljw/gen x)))

(defn generate
  "Generate a single value from generator g, using optional size (default 30)."
  ([g] (generate g 30))
  ([g size] ((:gen g) size)))

(defn return
  "Generator that always returns val."
  [val]
  (make-gen (fn [_] val)))

;;--- Layer 1: Combinators ---

(defn fmap
  "Create a generator that applies f to values from gen."
  [f gen]
  (make-gen (fn [size] (f ((:gen gen) size)))))

(defn bind
  "Create a generator that generates a value from gen, then passes it to f
   which returns a new generator, then generates from that."
  [gen f]
  (make-gen (fn [size]
              (let [inner ((:gen gen) size)
                    gen2 (f inner)]
                ((:gen gen2) size)))))

(defn one-of
  "Create a generator that randomly chooses from the given generators."
  [gens]
  (make-gen (fn [size]
              (let [g (rand-nth gens)]
                ((:gen g) size)))))

(defn such-that
  "Create a generator that generates values from gen satisfying pred.
   Tries up to max-tries times before throwing."
  [pred gen max-tries]
  (make-gen (fn [size]
              (loop [tries 0]
                (let [v ((:gen gen) size)]
                  (if (pred v)
                    v
                    (if (>= tries max-tries)
                      (throw (ex-info "Couldn't satisfy such-that predicate after max tries"
                                      {:max-tries max-tries :last-val v}))
                      (recur (inc tries)))))))))

(defn tuple
  "Create a generator that generates vectors with values from each gen."
  [& gens]
  (make-gen (fn [size]
              (clojure.core/mapv (fn [g] ((:gen g) size)) gens))))

(defn frequency
  "Create a generator that chooses from pairs of [weight gen] with
   probability proportional to weight."
  [pairs]
  (let [total (reduce + (mapv first pairs))]
    (make-gen (fn [size]
                (loop [n (rand-int total)
                       [[w g] & rest] pairs]
                  (if (<= n w)
                    ((:gen g) size)
                    (recur (- n w) rest)))))))

(defn hash-map
  "Create a generator that generates maps from alternating key gen pairs.
   (hash-map :a gen-int :b gen-str) => {:a 5 :b \"foo\"}"
  [& kvs]
  (let [pairs (vec (partition 2 kvs))]
    (make-gen (fn [size]
                (loop [result (clojure.core/array-map)
                       remaining pairs]
                  (if (empty? remaining)
                    result
                    (let [[k g] (first remaining)]
                      (recur (assoc result k ((:gen g) size))
                             (rest remaining)))))))))

(defn elements
  "Create a generator that randomly chooses from coll."
  [coll]
  (let [v (vec coll)]
    (make-gen (fn [_] (rand-nth v)))))

(defn vector
  "Create a generator that generates vectors of values from gen.
   Arities: (vector gen), (vector gen num), (vector gen min max)"
  ([gen] (vector gen 0 30))
  ([gen num-elements]
   (make-gen (fn [size]
               (clojure.core/vec (repeatedly num-elements #((:gen gen) size))))))
  ([gen min-elements max-elements]
   (make-gen (fn [size]
               (let [n (+ min-elements (rand-int (max 1 (inc (- max-elements min-elements)))))]
                 (clojure.core/vec (repeatedly n #((:gen gen) size))))))))

(defn vector-distinct
  "Create a generator that generates vectors of distinct values from gen.
   opts: :num-elements, :min-elements, :max-elements, :max-tries"
  [gen {:keys [num-elements min-elements max-elements max-tries]
        :or {min-elements 0 max-elements 30 max-tries 100}}]
  (let [min-el (or num-elements min-elements)
        max-el (or num-elements max-elements)]
    (make-gen (fn [size]
                (let [target (if num-elements
                               num-elements
                               (+ min-el (rand-int (max 1 (inc (- max-el min-el))))))]
                  (loop [result [] seen #{} tries 0]
                    (if (>= (count result) target)
                      result
                      (if (>= tries max-tries)
                        (throw (ex-info "Couldn't generate enough distinct values"
                                        {:target target :generated (count result)}))
                        (let [v ((:gen gen) size)]
                          (if (contains? seen v)
                            (recur result seen (inc tries))
                            (recur (conj result v) (conj seen v) tries)))))))))))

;;--- Layer 2: Delay + Collection generators ---

(defn delay-gen
  "Helper for delay macro. Takes a no-arg fn that returns a generator,
   returns a generator that invokes the fn at generation time."
  [f]
  (make-gen (fn [size] (let [g (f)] ((:gen g) size)))))

(defmacro delay
  "Create a generator that delays evaluation of body until generation time.
   Useful for recursive generators."
  [& body]
  ;; CLJW: avoid syntax-quote — CW macro expansion has issues with syntax-quote
  ;; across namespaces. Use manual form construction instead.
  (clojure.core/list 'clojure.spec.gen.alpha/delay-gen
                     (clojure.core/list* 'fn [] body)))

(defn list
  "Like vector but generates lists."
  ([gen] (fmap clojure.core/list* (vector gen))))

(defn map
  "Create a generator that generates maps from key-gen and val-gen."
  ([key-gen val-gen] (map key-gen val-gen {:num-elements nil :min-elements 0 :max-elements 10}))
  ([key-gen val-gen opts]
   (let [{:keys [num-elements min-elements max-elements]
          :or {min-elements 0 max-elements 10}} opts
         kv-gen (make-gen (fn [size]
                            [((:gen key-gen) size) ((:gen val-gen) size)]))]
     (if num-elements
       (fmap #(into {} %) (vector kv-gen num-elements))
       (fmap #(into {} %) (vector kv-gen min-elements max-elements))))))

(defn set
  "Like vector but generates sets."
  ([gen] (fmap #(into #{} %) (vector gen))))

(defn not-empty
  "Wrap gen to retry if it generates an empty collection."
  [gen]
  (such-that seq gen 100))

(defn cat
  "Concatenate generators into a single generator that produces a vector."
  [& gens]
  (make-gen (fn [size]
              (into [] (mapcat (fn [g]
                                 (let [v ((:gen g) size)]
                                   (if (sequential? v) v [v])))
                               gens)))))

(defn shuffle
  "Create a generator that generates shuffled versions of coll."
  [coll]
  (make-gen (fn [_]
              (let [v (clojure.core/vec coll)
                    n (count v)]
                (loop [i (dec n) v v]
                  (if (<= i 0)
                    v
                    (let [j (rand-int (inc i))]
                      (recur (dec i) (assoc v i (v j) j (v i))))))))))

;;--- Layer 3: Primitive generators ---

(def ^:private gen-int
  (make-gen (fn [size]
              (- (rand-int (inc (* 2 size))) size))))

(def ^:private gen-pos-int
  (make-gen (fn [size] (inc (rand-int size)))))

(def ^:private gen-nat
  (make-gen (fn [size] (rand-int (inc size)))))

(def ^:private gen-neg-int
  (make-gen (fn [size] (- (inc (rand-int size))))))

(def ^:private gen-boolean
  (make-gen (fn [_] (< (rand) 0.5))))

(def ^:private gen-char
  (make-gen (fn [_] (char (+ 32 (rand-int 95))))))

(def ^:private gen-char-alpha
  (make-gen (fn [_]
              (if (< (rand) 0.5)
                (char (+ 65 (rand-int 26)))
                (char (+ 97 (rand-int 26)))))))

(def ^:private gen-string
  (make-gen (fn [size]
              (let [n (rand-int (inc size))]
                (apply str (repeatedly n #((:gen gen-char) size)))))))

(def ^:private gen-keyword
  (make-gen (fn [size]
              (let [len (inc (rand-int (min size 20)))]
                (keyword (apply str (repeatedly len #((:gen gen-char-alpha) size))))))))

(def ^:private gen-keyword-ns
  (make-gen (fn [size]
              (let [len1 (inc (rand-int (min size 10)))
                    len2 (inc (rand-int (min size 10)))]
                (keyword (apply str (repeatedly len1 #((:gen gen-char-alpha) size)))
                         (apply str (repeatedly len2 #((:gen gen-char-alpha) size))))))))

(def ^:private gen-symbol
  (make-gen (fn [size]
              (let [len (inc (rand-int (min size 20)))]
                (symbol (apply str (repeatedly len #((:gen gen-char-alpha) size))))))))

(def ^:private gen-symbol-ns
  (make-gen (fn [size]
              (let [len1 (inc (rand-int (min size 10)))
                    len2 (inc (rand-int (min size 10)))]
                (symbol (apply str (repeatedly len1 #((:gen gen-char-alpha) size)))
                        (apply str (repeatedly len2 #((:gen gen-char-alpha) size))))))))

(def ^:private gen-double
  (make-gen (fn [size]
              (- (* (rand) 2.0 size) (double size)))))

(def ^:private gen-ratio
  (make-gen (fn [size]
              (let [n (- (rand-int (inc (* 2 size))) size)
                    d (inc (rand-int size))]
                (/ n d)))))

(defn boolean [] gen-boolean)
(defn bytes
  "Returns a generator for byte arrays."
  []
  (make-gen (fn [size]
              (let [n (rand-int (inc size))]
                (clojure.core/byte-array (repeatedly n #(unchecked-byte (- (rand-int 256) 128))))))))

(defn choose
  "Generator that returns longs in [lower, upper] inclusive."
  [lower upper]
  (make-gen (fn [_]
              (+ lower (rand-int (inc (- upper lower)))))))

(defn sample
  "Generate n (default 10) samples from generator."
  ([gen] (sample gen 10))
  ([gen n]
   (mapv #(generate gen %) (range 1 (inc n)))))

;;--- gen-for-pred: predicate-to-generator mapping ---

;; CLJW: Must use clojure.core/hash-map explicitly — CW compiles large map
;; literals (>8 entries) as hash-map calls, which would invoke our gen/hash-map.
(def ^:private gen-builtins
  (clojure.core/hash-map
   integer? gen-int
   int? gen-int
   pos-int? gen-pos-int
   neg-int? gen-neg-int
   nat-int? gen-nat
   even? (fmap #(* 2 %) gen-int)
   odd? (fmap #(inc (* 2 %)) gen-int)
   float? gen-double
   double? gen-double
   number? gen-int
   ratio? gen-ratio
   string? gen-string
   keyword? gen-keyword
   simple-keyword? gen-keyword
   qualified-keyword? gen-keyword-ns
   symbol? gen-symbol
   simple-symbol? gen-symbol
   qualified-symbol? gen-symbol-ns
   char? gen-char
   boolean? gen-boolean
   zero? (return 0)
   true? (return true)
   false? (return false)
   nil? (return nil)
   some? gen-int
   any? gen-int
   coll? (vector gen-int)
   list? (fmap clojure.core/list* (vector gen-int 0 5))
   vector? (vector gen-int 0 5)
   map? (map gen-keyword gen-int)
   set? (set gen-int)
   seq? (fmap seq (vector gen-int 1 5))
   seqable? (vector gen-int 0 5)
   sequential? (vector gen-int 0 5)
   associative? (vector gen-int 0 5)
   sorted? (fmap clojure.core/sorted-set (vector gen-int 0 5))
   counted? (vector gen-int 0 5)
   reversible? (vector gen-int 0 5)
   indexed? (vector gen-int 0 5)
   ident? gen-keyword
   qualified-ident? gen-keyword-ns
   simple-ident? gen-keyword
   pos? gen-pos-int
   neg? gen-neg-int
   empty? (return [])
   not-empty (vector gen-int 1 5)))

(defn gen-for-pred
  "Given a predicate, returns a generator for values satisfying that predicate,
   or nil if no generator can be found."
  [pred]
  (cond
    (clojure.core/set? pred) (elements pred)
    :else (get gen-builtins pred)))

;;--- Stubs for functions not yet needed ---

(defn large-integer*
  "Generator for large integers. opts: :min, :max"
  [opts]
  (let [mn (get opts :min -1000000)
        mx (get opts :max 1000000)]
    (choose mn mx)))

(defn double*
  "Generator for doubles. opts: :min, :max, :infinite?, :NaN?"
  [opts]
  (let [mn (get opts :min -1000.0)
        mx (get opts :max 1000.0)]
    (make-gen (fn [_] (+ mn (* (rand) (- mx mn)))))))

(def quick-check
  (fn [& _]
    (throw (ex-info "quick-check not implemented (requires test.check)" {}))))

(def for-all*
  (fn [& _]
    (throw (ex-info "for-all* not implemented (requires test.check)" {}))))
