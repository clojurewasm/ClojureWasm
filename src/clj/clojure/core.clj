;; clojure.core bootstrap — macros defined in Clojure, loaded at startup.
;;
;; These macros are evaluated by bootstrap.evalString during Env initialization.
;; Builtins (def, defmacro, fn, if, do, let, +, -, etc.) are already registered
;; in the Env by registry.registerBuiltins before this file is loaded.
;;
;; Migration status (All-Zig Phase A):
;; - All defn functions → bootstrap.zig (hot_core_defs, core_hof_defs, core_seq_defs)
;; - All def constants → bootstrap.zig (core_seq_defs)
;; - All macros → macro_transforms.zig (ns: A.11, other macros: A.1-A.9)
;; - Remaining here: `case` macro + private helpers (A.12 target)

;;; case — constant-time dispatch via case* special form

(defn- shift-mask [shift mask x]
  (-> x (bit-shift-right shift) (bit-and mask)))

(def ^:private max-mask-bits 13)
(def ^:private max-switch-table-size (bit-shift-left 1 max-mask-bits))

(defn- maybe-min-hash
  [hashes]
  (first
   (filter (fn [[s m]]
             (apply distinct? (map #(shift-mask s m %) hashes)))
           (for [mask (map #(dec (bit-shift-left 1 %)) (range 1 (inc max-mask-bits)))
                 shift (range 0 31)]
             [shift mask]))))

(defn- case-map
  [case-f test-f tests thens]
  (into (sorted-map)
        (zipmap (map case-f tests)
                (map vector
                     (map test-f tests)
                     thens))))

(defn- fits-table?
  [ints]
  (< (- (apply max (seq ints)) (apply min (seq ints))) max-switch-table-size))

(defn- prep-ints
  [tests thens]
  (if (fits-table? tests)
    [0 0 (case-map int int tests thens) :compact]
    (let [[shift mask] (or (maybe-min-hash (map int tests)) [0 0])]
      (if (zero? mask)
        [0 0 (case-map int int tests thens) :sparse]
        [shift mask (case-map #(shift-mask shift mask (int %)) int tests thens) :compact]))))

(defn- merge-hash-collisions
  [expr-sym default tests thens]
  (let [buckets (loop [m {} ks tests vs thens]
                  (if (and ks vs)
                    (recur
                     (update m (hash (first ks)) (fnil conj []) [(first ks) (first vs)])
                     (next ks) (next vs))
                    m))
        assoc-multi (fn [m h bucket]
                      (let [testexprs (mapcat (fn [kv] [(list 'quote (first kv)) (second kv)]) bucket)
                            expr `(condp = ~expr-sym ~@testexprs ~default)]
                        (assoc m h expr)))
        hmap (reduce
              (fn [m [h bucket]]
                (if (== 1 (count bucket))
                  (assoc m (ffirst bucket) (second (first bucket)))
                  (assoc-multi m h bucket)))
              {} buckets)
        skip-check (->> buckets
                        (filter #(< 1 (count (second %))))
                        (map first)
                        (into #{}))]
    [(keys hmap) (vals hmap) skip-check]))

(defn- prep-hashes
  [expr-sym default tests thens]
  (let [hashes (into #{} (map hash tests))]
    (if (== (count tests) (count hashes))
      (if (fits-table? hashes)
        [0 0 (case-map hash identity tests thens) :compact]
        (let [[shift mask] (or (maybe-min-hash hashes) [0 0])]
          (if (zero? mask)
            [0 0 (case-map hash identity tests thens) :sparse]
            [shift mask (case-map #(shift-mask shift mask (hash %)) identity tests thens) :compact])))
      (let [[tests thens skip-check] (merge-hash-collisions expr-sym default tests thens)
            [shift mask case-map switch-type] (prep-hashes expr-sym default tests thens)
            skip-check (if (zero? mask)
                         skip-check
                         (into #{} (map #(shift-mask shift mask %) skip-check)))]
        [shift mask case-map switch-type skip-check]))))

(defmacro case
  [e & clauses]
  (let [ge (gensym "case__")
        default (if (odd? (count clauses))
                  (last clauses)
                  `(throw (ex-info (str "No matching clause: " ~ge) {})))]
    (if (> 2 (count clauses))
      `(let [~ge ~e] ~default)
      (let [pairs (partition 2 clauses)
            assoc-test (fn assoc-test [m test expr]
                         (if (contains? m test)
                           (throw (ex-info (str "Duplicate case test constant: " test) {}))
                           (assoc m test expr)))
            pairs (reduce
                   (fn [m [test expr]]
                     (if (seq? test)
                       (reduce #(assoc-test %1 %2 expr) m test)
                       (assoc-test m test expr)))
                   {} pairs)
            tests (keys pairs)
            thens (vals pairs)
            mode (cond
                   (every? #(and (integer? %) (<= -2147483648 % 2147483647)) tests)
                   :ints
                   (every? keyword? tests)
                   :identity
                   :else :hashes)]
        (cond ;; CLJW: use cond instead of condp (condp defined after case)
          (= mode :ints)
          (let [[shift mask imap switch-type] (prep-ints tests thens)]
            `(let [~ge ~e] (case* ~ge ~shift ~mask ~default ~imap ~switch-type :int)))
          (= mode :hashes)
          (let [[shift mask imap switch-type skip-check] (prep-hashes ge default tests thens)]
            `(let [~ge ~e] (case* ~ge ~shift ~mask ~default ~imap ~switch-type :hash-equiv ~skip-check)))
          (= mode :identity)
          (let [[shift mask imap switch-type skip-check] (prep-hashes ge default tests thens)]
            `(let [~ge ~e] (case* ~ge ~shift ~mask ~default ~imap ~switch-type :hash-identity ~skip-check))))))))
