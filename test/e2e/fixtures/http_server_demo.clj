;; e2e fixture for cljw.http.server (ADR-0098 / D-257): a tiny Ring router that
;; exercises :request-method / :uri / :query-string / :headers / :body.
;; Binds 0.0.0.0:8157 (blocking, one request per connection).
(cljw.http.server/run-server
  (fn [req]
    (cond
      (= (:uri req) "/echo") {:status 200 :body (str "echo:" (:body req))}
      (= (:uri req) "/q")    {:status 200 :body (str "q:" (:query-string req))}
      (= (:uri req) "/h")    {:status 200 :body (str "h:" (get (:headers req) "x-test"))}
      (= (:request-method req) :post) {:status 201 :body "created"}
      :else {:status 200 :body (str "GET " (:uri req))}))
  {:port 8157})
