;; The order side effects happen in when an exception unwinds is the contract.
(prn (try 1 (catch Exception e :caught) (finally (println "finally-1"))))
(prn (try (throw (ex-info "x" {:a 1}))
          (catch clojure.lang.ExceptionInfo e [:info (ex-message e) (ex-data e)])
          (finally (println "finally-2"))))
(prn (try (/ 1 0) (catch ArithmeticException e (.getMessage e))))
(prn (try (throw (RuntimeException. "plain")) (catch Exception e (str "caught: " (.getMessage e)))))
;; A rethrow must not lose the original data.
(prn (try (try (throw (ex-info "inner" {:depth 1}))
               (catch Exception e (throw e)))
          (catch Exception e (ex-data e))))
