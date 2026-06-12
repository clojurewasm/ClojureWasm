;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.data.json API (originally Clojure contrib (data.json); Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.data.json — JSON read/write. cw v1 §9.11 row 9.3 landing.
;;
;; Surface mirrors JVM clojure.data.json 2.5.x: `read-str` parses a
;; JSON string into a cw value (vector / array_map / string / number
;; / nil / bool); `write-str` serialises a cw value into a JSON
;; string. The raw 1-arity parsers are the Zig primitives
;; `-read-str-impl` / `-write-str-impl` (interned by
;; `src/lang/primitive/json.zig::register`); the public `read-str` /
;; `write-str` below wrap them to add the `:key-fn` / `:value-fn`
;; options (D-401) via clojure.walk.
(ns clojure.data.json
  (:refer-clojure)
  (:require [clojure.walk]))

;; Apply :key-fn / :value-fn over every JSON object in `x`. `key-fn` maps each
;; key; `value-fn` maps (transformed-key, value) — a value-fn returning the
;; key-fn'd key is clj's "omit" sentinel, but cljw keeps the common shape simple.
(def ^:private -transform-json
  (fn* [x key-fn value-fn]
    (clojure.walk/postwalk
      (fn* [node]
        (if (map? node)
          (reduce-kv
            (fn* [m k v]
              (let* [k2 (if key-fn (key-fn k) k)
                     v2 (if value-fn (value-fn k2 v) v)]
                (assoc m k2 v2)))
            {} node)
          node))
      x)))

;; `(read-str s & {:keys [key-fn value-fn]})` — parse JSON, then apply the
;; post-process options. (`:bigdec` / `:eof-error?` / `:eof-value` are
;; parse-level and stay a `-read-str-impl` follow-up.)
(def read-str
  (fn [s & {:keys [key-fn value-fn]}]
    (let* [raw (-read-str-impl s)]
      (if (or key-fn value-fn)
        (-transform-json raw key-fn value-fn)
        raw))))

;; `(write-str x & {:keys [key-fn value-fn]})` — apply the options, then
;; serialise. key-fn typically stringifies keyword keys (e.g. `name`).
(def write-str
  (fn [x & {:keys [key-fn value-fn]}]
    (-write-str-impl
      (if (or key-fn value-fn)
        (-transform-json x key-fn value-fn)
        x))))
