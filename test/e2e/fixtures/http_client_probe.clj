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

;; NINE request headers — the :headers map promotes to hash_map (>8 entries,
;; Discussion #12 bug class); the client used to reject it as "not a map of
;; string→string". The server echoes x-h1 + x-h9 back, proving all arrived.
(let [r (cljw.http.client/get "http://127.0.0.1:8157/h9"
          {:headers {"x-h1" "a" "x-h2" "b" "x-h3" "c" "x-h4" "d" "x-h5" "e"
                     "x-h6" "f" "x-h7" "g" "x-h8" "h" "x-h9" "i"}})]
  (assert (= "h9:ai" (:body r)) (pr-str (:body r)))
  (println "PASS http-client-9-headers"))

;; A bad URL arg is a catchable cljw exception, not a crash.
(println "bad-url-caught:"
  (try (cljw.http.client/get 42) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))

(println "DONE")
