;; clojure.core.specs.alpha — Specs for clojure.core macros.
;; UPSTREAM-DIFF: Minimal implementation. Only includes non-spec helper functions.
;; Full spec definitions require clojure.spec.alpha integration.

(ns clojure.core.specs.alpha)

(defn even-number-of-forms?
  "Returns true if there are an even number of forms in a binding vector"
  [forms]
  (even? (count forms)))
