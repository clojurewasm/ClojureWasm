(require '[medley.core-test])
(let [result (clojure.test/run-tests 'medley.core-test)]
  (println "\nResult:" result)
  (when (or (pos? (:fail result)) (pos? (:error result)))
    (System/exit 1)))
