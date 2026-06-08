;; e2e fixture for cljw.http.server (ADR-0098 / D-257): a tiny Ring router that
;; exercises :request-method / :uri / :query-string / :headers / :body and the
;; response :headers map (Content-Type / custom headers).
;; Binds 0.0.0.0:8157 (blocking, one request per connection).
(cljw.http.server/run-server
  (fn [req]
    (cond
      (= (:uri req) "/echo") {:status 200 :body (str "echo:" (:body req))}
      (= (:uri req) "/q")    {:status 200 :body (str "q:" (:query-string req))}
      (= (:uri req) "/h")    {:status 200 :body (str "h:" (get (:headers req) "x-test"))}
      (= (:uri req) "/html") {:status 200
                              :headers {"content-type" "text/html; charset=utf-8"
                                        "x-custom" "yes"}
                              :body "<h1>hi</h1>"}
      ;; Out-of-range :status must NOT panic the server process — it falls back
      ;; to 500 (FIX-2 / SE-4). 200000 > 1023 would crash a bare @intCast(u10).
      (= (:uri req) "/badstatus") {:status 200000 :body "should become 500"}
      ;; A header value carrying CRLF (e.g. reflected request data) must NOT split
      ;; the response (SE-5 header injection). cljw rejects the dirty header at the
      ;; boundary → 500, never emitting the injected Set-Cookie.
      (= (:uri req) "/crlf-header") {:status 200
                                     :headers {"x-evil" "ok\r\nSet-Cookie: pwned=1"}
                                     :body "should become 500"}
      (= (:request-method req) :post) {:status 201 :body "created"}
      :else {:status 200 :body (str "GET " (:uri req))}))
  {:port 8157})
