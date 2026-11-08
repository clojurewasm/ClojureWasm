;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.data.csv API (originally Clojure contrib (data.csv); Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.data.csv — CSV read/write (RFC 4180). cw v1 §9.11 row 9.4.
;;
;; `read-csv` (string input + :separator/:quote options) is the Zig
;; primitive interned by `src/lang/primitive/csv.zig::register`; JVM's
;; Reader input is satisfied by the string arm (JVM read-csv accepts
;; String too). `write-csv` below is the JVM shape — writer-first,
;; returns nil — over the `-write-csv-str` impl (data + :separator/
;; :quote/:newline options → string); `(java.io.StringWriter.)` collects
;; output in memory exactly as on the JVM.
(ns clojure.data.csv
  (:refer-clojure))

(def ^{:doc "Writes data to writer in CSV-format. data is a sequence of
  sequences, one per row. Options are key-value pairs:

  :separator  — the field separator (default \\,)
  :quote      — the quote character (default \\\")
  :newline    — :lf or :cr+lf (default :lf)

  Returns nil."
       :arglists (quote ([writer data & options]))}
  write-csv
  (fn [writer data & options]
    (.write writer (apply -write-csv-str data options))
    nil))

;; `read-csv` is a Zig primitive (csv.zig), so its docs are attached here:
;; `(:doc (meta v))` is the one place `clojure.repl/doc`, `find-doc` and the
;; doc-coverage gate read.
(alter-meta! (var read-csv) merge
             {:doc "Reads CSV-data from the string s into a lazy sequence of vectors.

  Valid options are
    :separator (default \\,)
    :quote (default \\\")"
              :arglists (quote ([s] [s & options]))})
