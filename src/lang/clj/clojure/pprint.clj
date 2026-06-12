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

(def print-table
  (fn* [rows]
    (if (= 0 (count rows))
      nil
      (let* [ks (keys (first rows))
             header (clojure.string/join " | " (map str ks))
             sep (clojure.string/join "-+-" (map (fn* [k] (clojure.string/join "" (map (fn* [_] "-") (str k)))) ks))
             row-strs (map (fn* [row] (clojure.string/join " | " (map (fn* [k] (str (get row k))) ks))) rows)]
        (do
          (println header)
          (println sep)
          (reduce (fn* [_ s] (println s)) nil row-strs)
          nil)))))

;; `(cl-format stream fmt & args)` — a bounded Common-Lisp-format subset (D-403):
;; ~A aesthetic, ~S standard (pr-readable), ~D decimal, ~% newline, ~~ literal ~.
;; A nil stream returns the string; any other stream prints to *out* + returns nil.
;; Unsupported directives raise (no silent mishandle); the full DSL (~F float,
;; ~{~} iteration, column/justification, …) stays deferred.
(def cl-format
  (fn* [stream fmt & args]
    (let* [n (count fmt)
           result
           (loop* [i 0 as (seq args) acc ""]
             (if (>= i n)
               acc
               (let* [c (nth fmt i)]
                 (if (and (= c \~) (< (inc i) n))
                   (let* [d (nth fmt (inc i))]
                     (cond
                       (or (= d \a) (= d \A))
                       (let* [x (first as)]
                         (recur (+ i 2) (next as) (str acc (if (string? x) x (pr-str x)))))
                       (or (= d \s) (= d \S))
                       (recur (+ i 2) (next as) (str acc (pr-str (first as))))
                       (or (= d \d) (= d \D))
                       (recur (+ i 2) (next as) (str acc (str (first as))))
                       (= d \%)
                       (recur (+ i 2) as (str acc \newline))
                       (= d \~)
                       (recur (+ i 2) as (str acc \~))
                       :else
                       (throw (ex-info (str "cl-format: directive ~" d " is not supported in ClojureWasm") {}))))
                   (recur (inc i) as (str acc c))))))]
      (if (nil? stream)
        result
        (do (print result) nil)))))
