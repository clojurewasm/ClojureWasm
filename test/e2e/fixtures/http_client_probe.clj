;; e2e: cljw's own HTTP client round-trips against cljw's own HTTP server on
;; localhost — hermetic (no external network). Proves cljw.http.client/{get,post}
;; status + body capture against the http_server_demo fixture on :8157.
(let [r (cljw.http.client/get "http://127.0.0.1:8157/hello")]
  (assert (= 200 (:status r)) (str "status was " (:status r)))
  (assert (= "GET /hello" (:body r)) (pr-str (:body r)))
  (println "PASS http-client-get"))

(let [r (cljw.http.client/get "http://127.0.0.1:8157/q?a=1&b=2")]
  (assert (= "q:a=1&b=2" (:body r)) (pr-str (:body r)))
  (println "PASS http-client-query"))

(let [r (cljw.http.client/post "http://127.0.0.1:8157/echo" {:body "hi-from-client"})]
  (assert (= "echo:hi-from-client" (:body r)) (pr-str (:body r)))
  (println "PASS http-client-post-body"))

;; A bad URL arg is a catchable cljw exception, not a crash.
(println "bad-url-caught:"
  (try (cljw.http.client/get 42) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))

(println "DONE")
