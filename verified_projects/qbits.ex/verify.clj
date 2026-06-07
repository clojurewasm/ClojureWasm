;; qbits.ex — ex-info/ex-data-aware try+ with a library-scoped tag hierarchy.
;; Exercises `try+`'s `catch-data` clause (ancestor dispatch over the scoped
;; hierarchy) plus fall-through to a normal `catch` clause when no :type matches.
;; Run by `cljw -M:verify` (-> verify/-main).
(ns verify
  (:require [qbits.ex :as ex]))

(defn -main [& _]
  ;; library-scoped hierarchy: ::child derives from ::parent
  (ex/derive ::child ::parent)
  (assert (ex/isa? ::child ::parent))
  ;; catch-data matches a thrown ex-info on :type, honouring ancestors. try+
  ;; stashes the original exception in the ex-data's METADATA under
  ;; ::ex/exception (via vary-meta), so it is read through (meta d).
  (let [r (ex/try+
            (throw (ex-info "boom" {:type ::child :v 42}))
            (catch-data ::parent {:keys [v] :as d}
              [:caught v (instance? clojure.lang.ExceptionInfo
                                    (::ex/exception (meta d)))]))]
    (assert (= [:caught 42 true] r)))
  ;; no :type match -> rethrow through the normal catch clause
  (let [r2 (ex/try+
             (throw (ex-info "other" {:type ::unmatched}))
             (catch-data ::parent _ :wrong)
             (catch clojure.lang.ExceptionInfo e [:fell-through (:type (ex-data e))]))]
    (assert (= [:fell-through ::unmatched] r2)))
  (println "OK qbits.ex — try+ catch-data ancestor dispatch + normal-catch fall-through"))
