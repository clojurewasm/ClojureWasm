;; clojure.edn — EDN reader. cw v1 row 9.2 (D-074 close) landing.
;;
;; cw v1's core reader (src/eval/reader.zig) already understands EDN
;; syntax — Clojure source IS EDN with a quote-form interpretation.
;; This namespace exposes JVM-parity surface: `read-string` returns a
;; data Value (does NOT evaluate the form). The Layer-2 primitive is
;; interned by `modules/edn/edn.zig::register`; this `.clj` file's
;; only job is to (a) open the `clojure.edn` namespace, (b) optionally
;; re-export the var with metadata, (c) leave room for the
;; Pattern-A `read` / `parse` follow-up defns.
(ns clojure.edn
  (:refer-clojure))

;; `read-string` is interned by `src/lang/primitive/edn.zig` as a
;; builtin-fn Var on this namespace before `loadCore` reads this file.
;; No defn / declare needed here — `(declare)` is not yet wired in
;; cw v1's clojure.core. Both the 1-arity `(read-string s)` and the
;; 2-arity `(read-string opts s)` (`:readers` / `:default` / `:eof`,
;; ADR-0073 D-200) land in that primitive. Future cycle adds `(read)`
;; (reader-stream arity).
