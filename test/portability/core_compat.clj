;; Portability test: core language features
;; This file should produce identical output on JVM Clojure and ClojureWasm.
;; Run: clj -M test/portability/core_compat.clj
;; Run: cljw test/portability/core_compat.clj

;; --- Arithmetic ---
(println "add:" (+ 1 2 3))
(println "mul:" (* 2 3 4))
(println "div:" (quot 10 3))
(println "mod:" (mod 17 5))
(println "rem:" (rem 17 5))

;; --- Comparisons ---
(println "eq:" (= 1 1) (= 1 2))
(println "lt:" (< 1 2) (< 2 1))
(println "gte:" (>= 3 3) (>= 3 4))

;; --- Strings ---
(println "str:" (str "hello" " " "world"))
(println "count:" (count "hello"))
(println "subs:" (subs "hello" 1 3))

;; --- Collections ---
(println "vec:" [1 2 3])
(println "map:" (sorted-map :a 1 :b 2))
(println "set:" (sorted-set 3 1 2))
(println "list:" '(1 2 3))
(println "conj-vec:" (conj [1 2] 3))
(println "conj-list:" (conj '(1 2) 3))
(println "assoc:" (assoc {:a 1} :b 2))
(println "dissoc:" (dissoc {:a 1 :b 2} :b))
(println "get:" (get {:a 1 :b 2} :b))
(println "get-in:" (get-in {:a {:b 1}} [:a :b]))
(println "update:" (update {:a 1} :a inc))

;; --- Sequences ---
(println "map-fn:" (vec (map inc [1 2 3])))
(println "filter:" (vec (filter even? [1 2 3 4 5])))
(println "reduce:" (reduce + [1 2 3 4 5]))
(println "take:" (vec (take 3 (range 10))))
(println "drop:" (vec (drop 7 (range 10))))
(println "first:" (first [10 20 30]))
(println "rest:" (vec (rest [10 20 30])))
(println "cons:" (vec (cons 0 [1 2 3])))
(println "concat:" (vec (concat [1 2] [3 4])))
(println "interleave:" (vec (interleave [:a :b :c] [1 2 3])))
(println "partition:" (vec (map vec (partition 2 [1 2 3 4 5 6]))))
(println "frequencies:" (into (sorted-map) (frequencies [1 1 2 3 3 3])))
(println "group-by:" (into (sorted-map) (update-vals (group-by even? [1 2 3 4 5]) vec)))

;; --- Predicates ---
(println "nil?:" (nil? nil) (nil? 1))
(println "some?:" (some? nil) (some? 1))
(println "empty?:" (empty? []) (empty? [1]))
(println "coll?:" (coll? [1]) (coll? 1))
(println "seq?:" (seq? '(1)) (seq? [1]))
(println "map?:" (map? {}) (map? []))
(println "vector?:" (vector? []) (vector? '()))
(println "string?:" (string? "hi") (string? 1))
(println "number?:" (number? 1) (number? "1"))
(println "keyword?:" (keyword? :a) (keyword? "a"))
(println "symbol?:" (symbol? 'a) (symbol? :a))
(println "fn?:" (fn? inc) (fn? 1))

;; --- Control flow ---
(println "if:" (if true "yes" "no") (if false "yes" "no"))
(println "when:" (when true "yes"))
(println "cond:" (cond (= 1 2) "a" (= 1 1) "b" :else "c"))
(println "case:" (case 2 1 "one" 2 "two" "other"))
(println "or:" (or nil false 42))
(println "and:" (and 1 2 3))

;; --- Let / destructuring ---
(let [x 10 y 20] (println "let:" (+ x y)))
(let [[a b c] [1 2 3]] (println "destructure:" a b c))
(let [{:keys [x y]} {:x 10 :y 20}] (println "map-destr:" x y))

;; --- Functions ---
(println "apply:" (apply + [1 2 3]))
(println "comp:" ((comp inc inc) 5))
(println "partial:" ((partial + 10) 5))
(println "juxt:" ((juxt inc dec) 5))
(println "identity:" (identity 42))
(println "constantly:" ((constantly 42) :anything))

;; --- Atoms ---
(let [a (atom 0)]
  (swap! a inc)
  (swap! a + 10)
  (println "atom:" @a))

;; --- Strings (clojure.string) ---
(require '[clojure.string :as str])
(println "upper:" (str/upper-case "hello"))
(println "lower:" (str/lower-case "HELLO"))
(println "join:" (str/join ", " [1 2 3]))
(println "split:" (str/split "a,b,c" #","))
(println "replace:" (str/replace "hello world" "world" "clojure"))
(println "trim:" (str/trim "  hello  "))
(println "blank?:" (str/blank? "") (str/blank? "hi"))
(println "starts:" (str/starts-with? "hello" "he"))
(println "ends:" (str/ends-with? "hello" "lo"))
(println "includes:" (str/includes? "hello" "ell"))

;; --- Sets ---
(require '[clojure.set :as set])
(println "union:" (into (sorted-set) (set/union #{1 2} #{2 3})))
(println "intersection:" (into (sorted-set) (set/intersection #{1 2 3} #{2 3 4})))
(println "difference:" (into (sorted-set) (set/difference #{1 2 3} #{2 3})))

;; --- Walk ---
(require '[clojure.walk :as walk])
(println "postwalk:" (walk/postwalk #(if (number? %) (inc %) %) [1 [2 3]]))
(println "keywordize:" (walk/keywordize-keys {"a" 1 "b" 2}))

(println "--- DONE ---")
