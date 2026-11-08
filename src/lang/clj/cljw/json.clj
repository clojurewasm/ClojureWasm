;; cljw.json — handy JSON, require-able under the cljw.* namespace (ADR-0126
;; Cycle 7, user-requested). A THIN wrapper over clojure.data.json (the neutral
;; parse/emit impl lives in lang/primitive/json.zig per F-009 — this never
;; forks it) plus map<->JSON convenience. Requires clojure.data.json +
;; clojure.walk (declared below).
(ns cljw.json
  (:require [clojure.data.json]
            [clojure.walk]))

;; Re-exports (so `(require '[cljw.json :as json])` gives the data.json surface).
;; Delegating defns, not `(def write-str clojure.data.json/write-str)`: a
;; def-alias captures the fn VALUE at load time, so a later redefinition or a
;; `with-redefs` of the data.json var would not reach these, and the alias var
;; would carry no :doc / :arglists.
(defn write-str
  "Converts x to a JSON-formatted string. Delegates to
   clojure.data.json/write-str at call time; options are its key-value pairs
   (:key-fn, :value-fn, :escape-unicode, :escape-slash,
   :escape-js-separators)."
  [x & options]
  (apply clojure.data.json/write-str x options))

(defn read-str
  "Reads one JSON value from the string s. Delegates to
   clojure.data.json/read-str at call time; options are its key-value pairs."
  [s & options]
  (apply clojure.data.json/read-str s options))

(defn encode
  "A cljw value -> a JSON string. (Alias of write-str, the natural map->JSON
   direction.)"
  [x]
  (clojure.data.json/write-str x))

(defn decode
  "A JSON string -> a cljw value with map keys keywordized recursively (the
   common `cheshire/parse-string s true` shape). Use decode-strict for string
   keys."
  [s]
  (clojure.walk/keywordize-keys (clojure.data.json/read-str s)))

(defn decode-strict
  "A JSON string -> a cljw value with string map keys (data.json default)."
  [s]
  (clojure.data.json/read-str s))
