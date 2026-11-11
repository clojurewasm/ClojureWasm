(ns demo.core
  "A Clojure library compiled by jolt into a C-ABI shared object.

  `jolt build --library -m demo.core -o libdemo` turns each export! below
  into a C entry point reached through jolt_lookup, after jolt_library_init."
  (:require [clojure.string :as str]
            [jolt.ffi :as ffi]))

(defn add [a b] (+ a b))

(defn mandel
  "Escape iteration count of c = cr + ci*i, capped at max-iter."
  [cr ci max-iter]
  (loop [zr 0.0 zi 0.0 i 0]
    (if (or (>= i max-iter) (> (+ (* zr zr) (* zi zi)) 4.0))
      i
      (recur (+ (- (* zr zr) (* zi zi)) cr)
             (+ (* 2.0 zr zi) ci)
             (inc i)))))

;; The hive C ABI: hive_call(op, json) -> char*, hive_free(char*).
;; jolt ships no JSON library, so the envelope is written by hand and a
;; payload is read as a flat object of numbers, which is all these ops take.

(defn- json-str [s]
  (str "\"" (-> s (str/replace "\\" "\\\\") (str/replace "\"" "\\\"")) "\""))

(defn- write-json [v]
  (cond
    (nil? v) "null"
    (string? v) (json-str v)
    (keyword? v) (json-str (name v))
    (or (number? v) (boolean? v)) (str v)
    (map? v) (str "{" (str/join "," (map (fn [[k x]] (str (write-json k) ":" (write-json x))) v)) "}")
    (sequential? v) (str "[" (str/join "," (map write-json v)) "]")
    :else (json-str (str v))))

(defn- read-flat-numbers [s]
  (into {}
        (map (fn [[_ k n]] [(keyword k) (parse-double n)]))
        (re-seq #"\"([^\"]+)\"\s*:\s*(-?[0-9.eE+-]+)" (or s ""))))

(def ^:private ops
  {"ops"    {:doc "List the ops this library answers." :args []}
   "add"    {:doc "Sum of a and b." :args ["a" "b"]}
   "mandel" {:doc "Escape count of cr + ci*i, capped at max." :args ["cr" "ci" "max"]}})

(defn- dispatch [op p]
  (case op
    "ops" (mapv (fn [[n m]] (assoc m :name n)) (sort-by key ops))
    "add" (+ (:a p 0) (:b p 0))
    "mandel" (mandel (:cr p 0.0) (:ci p 0.0) (long (:max p 100)))
    (throw (ex-info (str "unknown op " op) {}))))

(defn hive-call [op json]
  (ffi/string->ptr
   (write-json
    (try {:ok true :value (dispatch op (read-flat-numbers json))}
         (catch Exception e {:ok false :error (ex-message e)})))))

(defn hive-free [p] (ffi/free p) nil)

(ffi/export! "add" add [:int :int] :int)
(ffi/export! "mandel" mandel [:double :double :int] :int)
(ffi/export! "hive_call" hive-call [:string :string] :pointer)
(ffi/export! "hive_free" hive-free [:pointer] :void)
