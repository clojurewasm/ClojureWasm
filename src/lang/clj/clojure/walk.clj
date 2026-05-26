;; clojure.walk — Phase 6.11 cycle 1 + Phase 6.16.c Group A.
;;
;; Loaded by `src/lang/bootstrap.zig::loadCore` per ADR-0032's
;; multi-file FILES table. The `walk` spine var is a Zig leaf
;; (B2 placement preserved per v5 §9.1) at
;; `src/lang/primitive/walk.zig`; `prewalk` + `postwalk` are
;; Pattern A defns below (Phase 6.16.c Group A migration —
;; previously Zig leaves in the same file).
;;
;; Self-recursive defns use the two-step pattern (`(def name nil)`
;; then `(def name (fn* ...))`) so the inner fn body's symbol
;; resolution finds the Var by the time `analyzeSymbol` runs.
;; cw v1 has no `declare` macro yet.

(ns clojure.walk (:refer-clojure))

;; prewalk: pre-order recursion — apply f at this level first, then
;; recurse over the result's one-level children via walk.
;; JVM: (defn prewalk [f form] (walk (partial prewalk f) identity (f form)))
;; cw v1: no partial / identity in scope here, so inline both.
(def prewalk nil)
(def prewalk
  (fn* [f form]
    (walk (fn* [child] (prewalk f child))
          (fn* [x] x)
          (f form))))

;; postwalk: post-order recursion — recurse over children first, then
;; apply f at this level.
;; JVM: (defn postwalk [f form] (walk (partial postwalk f) f form))
(def postwalk nil)
(def postwalk
  (fn* [f form]
    (walk (fn* [child] (postwalk f child))
          f
          form)))

;; prewalk-replace / postwalk-replace: walk form replacing every
;; sub-form that is a key in `smap` with the corresponding value.
;; JVM: (defn postwalk-replace [smap form]
;;        (postwalk (fn [x] (if (contains? smap x) (smap x) x)) form))
;; cw v1 spells the map lookup as `(get smap x)` rather than `(smap x)`
;; — same semantic, no dependence on the map-as-function invoke path.
(def prewalk-replace
  (fn* [smap form]
    (prewalk (fn* [x] (if (contains? smap x) (get smap x) x)) form)))

(def postwalk-replace
  (fn* [smap form]
    (postwalk (fn* [x] (if (contains? smap x) (get smap x) x)) form)))

;; keywordize-keys: recursively convert string keys to keywords.
;; JVM uses vector destructure `[[k v]]` inside the helper fn;
;; cw v1's let* has no destructure (D-076), so we fold over (keys m)
;; with explicit (get m k). Same complexity, more verbose.
(def keywordize-keys
  (fn* [m]
    (postwalk
      (fn* [x]
        (if (map? x)
          (reduce
            (fn* [acc k]
              (if (string? k)
                (assoc acc (keyword k) (get x k))
                (assoc acc k (get x k))))
            {}
            (keys x))
          x))
      m)))

;; stringify-keys: inverse of keywordize-keys — keyword keys → strings.
(def stringify-keys
  (fn* [m]
    (postwalk
      (fn* [x]
        (if (map? x)
          (reduce
            (fn* [acc k]
              (if (keyword? k)
                (assoc acc (name k) (get x k))
                (assoc acc k (get x k))))
            {}
            (keys x))
          x))
      m)))

;; prewalk-demo / postwalk-demo: walk `form` printing each visited
;; subform via println; return the (unmodified) form. JVM also calls
;; print + println for the "Walked: " prefix; cw v1 ships the
;; bare println form for minimal prereq surface.
(def prewalk-demo
  (fn* [form] (prewalk (fn* [x] (println x) x) form)))

(def postwalk-demo
  (fn* [form] (postwalk (fn* [x] (println x) x) form)))
