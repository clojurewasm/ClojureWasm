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
      ;; Binary body: a primitive byte-array :body is copied verbatim. Every
      ;; byte value 0..255 once, so a UTF-8-normalising path would corrupt it
      ;; (bytes >= 0x80 expand) and the length alone detects the regression.
      (= (:uri req) "/bytes") {:status 200
                               :headers {"content-type" "application/octet-stream"}
                               :body (byte-array (map unchecked-byte (range 256)))}
      ;; Out-of-range :status must NOT panic the server process — it falls back
      ;; to 500 (FIX-2 / SE-4). 200000 > 1023 would crash a bare @intCast(u10).
      (= (:uri req) "/badstatus") {:status 200000 :body "should become 500"}
      ;; A header value carrying CRLF (e.g. reflected request data) must NOT split
      ;; the response (SE-5 header injection). cljw rejects the dirty header at the
      ;; boundary → 500, never emitting the injected Set-Cookie.
      (= (:uri req) "/crlf-header") {:status 200
                                     :headers {"x-evil" "ok\r\nSet-Cookie: pwned=1"}
                                     :body "should become 500"}
      ;; 9-entry maps promote past the array_map ceiling (Discussion #12 bug
      ;; class): /h9 reads two of NINE request headers; /many-headers returns
      ;; NINE response headers (>8 used to be dropped wholesale server-side).
      (= (:uri req) "/h9") {:status 200
                            :body (str "h9:" (get (:headers req) "x-h1")
                                       (get (:headers req) "x-h9"))}
      (= (:uri req) "/many-headers") {:status 200
                                      :headers {"x-m1" "1" "x-m2" "2" "x-m3" "3"
                                                "x-m4" "4" "x-m5" "5" "x-m6" "6"
                                                "x-m7" "7" "x-m8" "8" "x-m9" "9"}
                                      :body "many"}
      (= (:request-method req) :post) {:status 201 :body "created"}
      :else {:status 200 :body (str "GET " (:uri req))}))
  ;; :header-timeout-ms is short here so the D-339 slowloris case runs fast;
  ;; the shipped default is 10000. Legitimate requests complete in milliseconds,
  ;; so 1500 does not affect the other cases.
  {:port 8157 :header-timeout-ms 1500})
