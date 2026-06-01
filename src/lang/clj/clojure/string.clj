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
(def index-of        (fn* ([s sub] (-index-of s sub)) ([s sub from] (-index-of s sub from))))
(def last-index-of   (fn* ([s sub] (-last-index-of s sub)) ([s sub from] (-last-index-of s sub from))))
(def reverse         (fn* [s] (-reverse s)))

;; Phase 6.16.e.1 — GREEN trio (v5 §9.2). Pure rename-and-shim
;; matching the 6.16.d Pattern B2 shape (the survey classified
;; these as "Pattern A" because the surface is pure Clojure
;; composition; the underlying string scanning is still in Zig).
(def blank?          (fn* [s] (-blank? s)))
(def split           (fn* ([s re] (-split s re)) ([s re limit] (-split s re limit))))
(def split-lines     (fn* [s] (-split-lines s)))

;; Phase 6.16.e.2 — YELLOW pair (capitalize / join) per v5 §9.2.
;; Pure-Clojure compositions over `str` + `subs` + the existing
;; case-fold leaves.

;; capitalize: upper-case first codepoint + lower-case rest.
;; JVM: (str (Character/toUpperCase (.charAt s 0)) (-lower-case (subs s 1)))
;; cw v1: upper-case the 1-codepoint prefix to handle non-ASCII
;; uniformly with the existing Zig case-fold (which is ASCII-only —
;; D-057 tracks the Unicode lift).
(def capitalize
  (fn* [s]
    (if (< (count s) 2)
      (-upper-case s)
      (str (-upper-case (subs s 0 1))
           (-lower-case (subs s 1))))))

;; join: 1-arity (coll) = (apply str coll); 2-arity (sep coll) folds
;; with explicit separator insertion. Variadic via `[& args]` + count
;; discrimination since cw v1 lacks multi-arity `fn*` (D-070).
;; (join sep) transducer arity is deferred (D-070 + ADR-0033 D6a).
;;
;; The 2-arity body uses a nil sentinel for the initial accumulator
;; because cw v1's `=` is currently number-only (string equality
;; lives in `identical?` for interned cases but not for general string
;; compares yet). The nil sentinel + `nil?` check works regardless.
(def join
  (fn* [& args]
    (if (= 1 (count args))
      (apply str (first args))
      ;; str (reduce ...) coerces a nil result (empty input) to "".
      (str (reduce
             (fn* [acc x]
               (if (nil? acc) (str x) (str acc (first args) x)))
             nil
             (first (rest args)))))))

;; ----------------------------------------------------------------
;; Row 7.12 cycle 3 (D-078): `replace` / `replace-first` Pattern A
;; landing. The macro `instance?` (row 7.12 cycle 1) auto-quotes
;; its Class symbol, so `(instance? String match)` dispatches
;; through the runtime/class_name.zig registry without explicit
;; quote. The 6 private leaves landed at row 7.12 cycle 2 carry
;; the actual string / char / regex match logic; this Pattern A
;; defn is the public Clojure surface routing on `match`'s tag.
;; The regex-string `repl` arm treats `$N` as literal pass-through
;; (PROVISIONAL — D-093, D-051 cycle 3 closure).
;; ----------------------------------------------------------------

;; Character literal reader / `(char N)` constructor are not yet
;; user-accessible (see future debt — char Values land via primitive
;; surfaces only today), so the Character arm below is correct but
;; unreachable from .clj source until that lands. Tests cover it
;; via the Zig leaf directly.
(def replace
  (fn* [s match repl]
    (cond
      (instance? String match)  (-str-replace-string s match repl)
      (instance? Character match) (-str-replace-char s match repl)
      (instance? Pattern match) (-str-replace-pattern s match repl)
      :else (throw (ex-info "replace: unsupported match type"
                            {:fn "replace" :match match})))))

(def replace-first
  (fn* [s match repl]
    (cond
      (instance? String match)  (-str-replace-first-string s match repl)
      (instance? Character match) (-str-replace-first-char s match repl)
      (instance? Pattern match) (-str-replace-first-pattern s match repl)
      :else (throw (ex-info "replace-first: unsupported match type"
                            {:fn "replace-first" :match match})))))
