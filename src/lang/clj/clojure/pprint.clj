;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.pprint API (originally Tom Faulhaber; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.pprint — minimum pretty-print surface. cw v1 §9.12 row 10.2.
;;
;; Pattern A defns over clojure.core/println + clojure.string/join.
;; `pprint` currently aliases to `println` (cw v1's default `prn`
;; output already matches JVM short-form pretty-print for the
;; map / vector / set / list literals that the existing reader
;; produces); a real width-aware indenter is deferred until
;; user demand surfaces.
;; `print-table` formats a seq of maps with shared keys as a
;; pipe-separated table; takes the keys from the first row.
;; `cl-format` and the rest of JVM clojure.pprint surface are
;; deferred — they require a non-trivial formatting DSL impl that
;; lands when needed.
(ns clojure.pprint
  (:refer-clojure))

;; Dispatch surface (D-402). cljw has no width-aware indenter / code-specific
;; formatter, so both dispatches are the SAME pr-readable single-line printer (a
;; documented divergence from JVM pprint's multi-line layout + code indentation).
;; The indirection exists so `with-pprint-dispatch` / `code-dispatch` resolve and
;; bind — what macro-pretty-printing libs need (clojure.tools.logging's `spy`).
;; Using `pr` (not `println`) also fixes the string-quoting divergence: cljw
;; `(pprint "x")` now prints `"x"`, matching clj, not the bare `x` println gave.
(def simple-dispatch (fn* [x] (pr x)))
(def code-dispatch (fn* [x] (pr x)))

(def ^:dynamic *print-pprint-dispatch* simple-dispatch)

(defmacro with-pprint-dispatch
  "Evaluate `body` with *print-pprint-dispatch* bound to `dispatch`."
  [dispatch & body]
  `(binding [*print-pprint-dispatch* ~dispatch] ~@body))

(def pprint
  (fn* [x] (*print-pprint-dispatch* x) (newline)))

;; `print-table` — clj's exact format (F-011): a leading blank line, a padded
;; `| col | col |` header, a `|----+----|` rule, then one padded row per map.
;; Column width = max(key width, widest value). `ks` defaults to the first row's
;; keys. Ported from clojure.pprint/print-table (was a simpler non-matching form).
(defn print-table
  ([ks rows]
   (when (seq rows)
     (let [widths (map (fn [k] (apply max (count (str k)) (map (fn [r] (count (str (get r k)))) rows))) ks)
           spacers (map (fn [w] (apply str (repeat w "-"))) widths)
           fmts (map (fn [w] (str "%" w "s")) widths)
           fmt-row (fn [leader divider trailer row]
                     (str leader
                          (apply str (interpose divider
                                                (for [pair (map vector (map (fn [k] (get row k)) ks) fmts)]
                                                  (format (second pair) (str (first pair))))))
                          trailer))]
       (println)
       (println (fmt-row "| " " | " " |" (zipmap ks ks)))
       (println (fmt-row "|-" "-+-" "-|" (zipmap ks spacers)))
       (doseq [row rows] (println (fmt-row "| " " | " " |" row))))))
  ([rows] (print-table (keys (first rows)) rows)))

;; `(cl-format stream fmt & args)` — Common-Lisp-format subset (D-403 + D-455).
;; ~A aesthetic, ~S standard (pr-readable), ~D decimal, ~F fixed float, ~X/~O radix,
;; ~B binary, ~% newline, ~~ literal ~. Number directives parse the
;; `~mincol,'padchar` parameter grammar (+ `:` grouped) and delegate to `format`.
;; A nil stream returns the string; any other stream prints to *out* + returns nil.
;; Still-deferred directives (~{~} iteration, ~R cardinal, ~:( case) raise (no
;; silent mishandle). cl-* helpers are clojure.pprint internals.
(defn cl-digit? [c] (let [i (int c)] (and (>= i (int \0)) (<= i (int \9)))))
(defn cl-int [c] (- (int c) (int \0)))

;; Parse a directive's `~[params][:][@]d` prefix from `fmt` starting at `i` (the
;; char just after `~`). Returns [params colon? at? directive-char next-i], where
;; params is a vector of (long | char | nil) — `~5,'0d` → [5 \0], `~,2f` → [nil 2].
(defn cl-dir [fmt i]
  (loop [j i params [] cur nil cur? false colon? false at? false]
    (let [c (nth fmt j)]
      (cond
        (cl-digit? c) (recur (inc j) params (+ (* (or cur 0) 10) (cl-int c)) true colon? at?)
        (= c \') (recur (+ j 2) (conj params (nth fmt (inc j))) nil false colon? at?)
        (= c \,) (recur (inc j) (conj params (if cur? cur nil)) nil false colon? at?)
        (= c \:) (recur (inc j) params cur cur? true at?)
        (= c \@) (recur (inc j) params cur cur? colon? true)
        :else [(if cur? (conj params cur) params) colon? at? c (inc j)]))))

;; Left-pad `s` to `width` with `padchar` (CL-format right-justification default).
(defn cl-pad [s width padchar]
  (let [len (count s) w (or width 0)]
    (if (< len w) (str (apply str (repeat (- w len) padchar)) s) s)))

(defn cl-format [stream fmt & args]
  (let [n (count fmt)
        result
        (loop [i 0 as (seq args) acc ""]
          (if (>= i n)
            acc
            (let [c (nth fmt i)]
              (if (and (= c \~) (< (inc i) n))
                (let [pd (cl-dir fmt (inc i))
                      params (nth pd 0) colon? (nth pd 1) d (nth pd 3) ni (nth pd 4)
                      p0 (first params) p1 (second params) x (first as)]
                  (cond
                    (or (= d \a) (= d \A)) (recur ni (next as) (str acc (if (string? x) x (pr-str x))))
                    (or (= d \s) (= d \S)) (recur ni (next as) (str acc (pr-str x)))
                    (or (= d \d) (= d \D))
                    (recur ni (next as) (str acc (cl-pad (if colon? (format "%,d" x) (str x)) p0 (or p1 \space))))
                    (or (= d \f) (= d \F))
                    (recur ni (next as) (str acc (format (str "%" (if p0 p0 "") "." (or p1 0) "f") (double x))))
                    (or (= d \x) (= d \X)) (recur ni (next as) (str acc (cl-pad (format "%x" x) p0 (or p1 \space))))
                    (or (= d \o) (= d \O)) (recur ni (next as) (str acc (cl-pad (format "%o" x) p0 (or p1 \space))))
                    (or (= d \b) (= d \B)) (recur ni (next as) (str acc (cl-pad (Long/toBinaryString x) p0 (or p1 \space))))
                    (= d \%) (recur ni as (str acc \newline))
                    (= d \~) (recur ni as (str acc \~))
                    :else (throw (ex-info (str "cl-format: directive ~" d " is not supported in ClojureWasm") {}))))
                (recur (inc i) as (str acc c))))))]
    (if (nil? stream) result (do (print result) nil))))
