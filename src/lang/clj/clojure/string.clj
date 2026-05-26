;; clojure.string — ADR-0032 + ADR-0029 + Phase 6.9 cycle 1.
;;
;; Loaded by `src/lang/bootstrap.zig::loadCore` after `core.clj`.
;; The (in-ns) header is mandatory — the bootstrap loader carries no
;; namespace knowledge, so each multi-file source declares its own
;; namespace via the analyzer special form `in-ns` (ADR-0032).
;;
;; Cycle 1 ships nothing in this file beyond the (in-ns) header —
;; upper-case / lower-case / blank? are registered into clojure.string
;; from `src/lang/primitive/string.zig` because pure-Clojure
;; implementations would need primitives that haven't landed yet
;; (codepoint iteration callouts to runtime/charset.zig). Cycles 2-4
;; add Clojure-side defns for composite vars (capitalize uses upper +
;; lower + subs; split-lines uses a small regex; etc.) per the
;; per-task survey at private/notes/phase6-6.9-survey.md §6.

(ns clojure.string (:refer-clojure))

;; ----------------------------------------------------------------
;; Phase 6.16.d Pattern B2 shim layer (v5 §8.1 + §9.2)
;;
;; 12 user-visible Vars below are 1-line shim defns over `-name`
;; Pattern B2 leaves interned with `.private = true` in the same
;; ns (see `src/lang/primitive/string.zig::LEAF_ENTRIES`). Surface
;; semantics are unchanged from the previous Zig-direct registration;
;; the migration adds Layer 3 visibility for future Pattern A
;; rewrites (e.g., a future cycle could replace `(def upper-case ...)`
;; with a Unicode-aware Pattern A body without touching every caller).
;;
;; The `-name` leaves are private to clojure.string per ADR-0033 D4:
;; intra-ns shim resolution is same-ns (passes the analyzer's
;; cross-ns private check); user-ns callers reaching for
;; `clojure.string/-upper-case` trip the check with
;; `private_access_error`.
;; ----------------------------------------------------------------

(def upper-case      (fn* [s] (-upper-case s)))
(def lower-case      (fn* [s] (-lower-case s)))
(def trim            (fn* [s] (-trim s)))
(def triml           (fn* [s] (-triml s)))
(def trimr           (fn* [s] (-trimr s)))
(def trim-newline    (fn* [s] (-trim-newline s)))
(def starts-with?    (fn* [s sub] (-starts-with? s sub)))
(def ends-with?      (fn* [s sub] (-ends-with? s sub)))
(def includes?       (fn* [s sub] (-includes? s sub)))
(def index-of        (fn* [s sub] (-index-of s sub)))
(def last-index-of   (fn* [s sub] (-last-index-of s sub)))
(def reverse         (fn* [s] (-reverse s)))

;; Phase 6.16.e.1 — GREEN trio (v5 §9.2). Pure rename-and-shim
;; matching the 6.16.d Pattern B2 shape (the survey classified
;; these as "Pattern A" because the surface is pure Clojure
;; composition; the underlying string scanning is still in Zig).
(def blank?          (fn* [s] (-blank? s)))
(def split           (fn* [s re] (-split s re)))
(def split-lines     (fn* [s] (-split-lines s)))
