;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.edn API (originally Rich Hickey; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.edn — EDN reader. cw v1 row 9.2 (D-074 close) landing.
;;
;; cw v1's core reader (src/eval/reader.zig) already understands EDN
;; syntax — Clojure source IS EDN with a quote-form interpretation.
;; This namespace exposes JVM-parity surface: `read-string` returns a
;; data Value (does NOT evaluate the form). The Layer-2 primitive is
;; interned by `src/lang/primitive/edn.zig::register`; this `.clj` file's
;; only job is to (a) open the `clojure.edn` namespace, (b) optionally
;; re-export the var with metadata, (c) leave room for the
;; Pattern-A `parse` follow-up defns.
(ns clojure.edn
  (:refer-clojure))

;; `read-string` is interned by `src/lang/primitive/edn.zig` as a
;; builtin-fn Var on this namespace before `loadCore` reads this file,
;; so no defn / declare is needed here. Both the 1-arity
;; `(read-string s)` and the 2-arity `(read-string opts s)`
;; (`:readers` / `:default` / `:eof`, ADR-0073 D-200) land in that
;; primitive. `(read)`, `(read reader)`, and `(read opts reader)` share
;; its EDN option handling and consume only one form per call.
