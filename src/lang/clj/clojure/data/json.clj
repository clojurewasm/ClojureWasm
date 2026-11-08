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
  (:require [clojure.walk]
            [clojure.string]))

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

;; `(read-str s & {:keys [key-fn value-fn eof-error? eof-value]})` — parse JSON,
;; then apply the post-process options. Empty/blank input with `:eof-error? false`
;; returns `:eof-value` (default nil); otherwise it throws like a parse error.
;; (`:bigdec` is parse-level and stays a `-read-str-impl` follow-up.)
(def ^{:doc "Reads one JSON value from input String s. Options are key-value pairs:

  :key-fn      — applied to each JSON property name (default identity; use
                 clojure.core/keyword to get keyword keys)
  :value-fn    — applied to each [key value] pair, returning the replacement
                 value
  :eof-error?  — throw on empty input rather than returning :eof-value
                 (default true)
  :eof-value   — what an empty input returns when :eof-error? is false"
       :arglists (quote ([s & options]))}
  read-str
  (fn [s & {:keys [key-fn value-fn eof-error? eof-value]
            :or {eof-error? true}}]
    (if (clojure.string/blank? s)
      (if eof-error?
        (throw (ex-info "JSON error (end-of-input)" {}))
        eof-value)
      (let* [raw (-read-str-impl s)]
        (if (or key-fn value-fn)
          (-transform-json raw key-fn value-fn)
          raw)))))

;; `(write-str x & {:keys [key-fn value-fn escape-unicode escape-slash
;; escape-js-separators]})` — apply the transform options, then serialise.
;; key-fn typically stringifies keyword keys (e.g. `name`). The escape
;; options default true (the JVM data.json defaults) and ride through to
;; the Zig writer as a map.
(def ^{:doc "Converts x to a JSON-formatted string. Options are key-value pairs:

  :key-fn                — applied to each map key before writing
  :value-fn              — applied to each [key value] pair, returning the
                           replacement value
  :escape-unicode        — escape non-ASCII as \\uXXXX (default true)
  :escape-slash          — escape / as \\/ (default true)
  :escape-js-separators  — escape U+2028 and U+2029, which are literal
                           line terminators in JavaScript (default true)"
       :arglists (quote ([x & options]))}
  write-str
  (fn [x & {:keys [key-fn value-fn escape-unicode escape-slash escape-js-separators]
            :or {escape-unicode true escape-slash true escape-js-separators true}}]
    (-write-str-impl
      (if (or key-fn value-fn)
        (-transform-json x key-fn value-fn)
        x)
      {:escape-unicode escape-unicode
       :escape-slash escape-slash
       :escape-js-separators escape-js-separators})))
