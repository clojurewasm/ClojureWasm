;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.instant API (originally Rich Hickey / Stuart
;; Halloway; Clojure, EPL-1.0) for ClojureWasm; no upstream source text is reproduced.
;;
;; The `#inst "…"` reader literal + Date print are ClojureWasm built-ins, backed by the
;; canonical instant parser (runtime/time/instant.zig). `read-instant-date` exposes that
;; parser as a fn (clj-faithful: clj's read-instant-date also returns a Date).
;;
;; `read-instant-timestamp` / `read-instant-calendar` are NOT provided yet: ClojureWasm
;; models a single Date instant and has no java.sql.Timestamp / java.util.Calendar type.
;; Collapsing them to Date is a smell (user 2026-06-10); the finished form is a NEUTRAL
;; time model in runtime/time/ (Zig 0.16.0 std.time) surfaced thinly per-namespace (F-009)
;; — tracked in D-382. Until then they are intentionally absent (an honest NameError),
;; not a fake-Date collapse.

(ns clojure.instant)

(defn- parse-inst
  "Parse an instant string into a java.util.Date via the canonical #inst reader.
  A valid instant string is reader-quote-free; a `\"` / `\\` would let the reader
  consume a partial form, so reject those (malformed → throw), matching clj's
  reject-bad-input contract. (Char-set guard, not a regex literal — regex literals
  are unsupported in a bootstrap-loaded namespace.)"
  [s]
  (if (and (string? s) (not (some #{\" \\} s)))
    (read-string (str "#inst \"" s "\""))
    (throw (ex-info "Invalid instant string" {:s s}))))

(defn read-instant-date
  "Parse an RFC3339-like instant string into a java.util.Date (the #inst reader fn)."
  [s] (parse-inst s))
