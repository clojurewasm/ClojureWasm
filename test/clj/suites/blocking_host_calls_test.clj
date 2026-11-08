;; A worker thread blocked in a host call does not stall collections that
;; another thread requests (safepoint.blocking): cljw.net accept and read,
;; cljw.http.client, and Thread/sleep.
;;
;; Run by `test/clj/run_suites.clj`. Loopback only. Each peer is a separate OS
;; process (bash over /dev/tcp, or a child cljw), so no waker can itself be
;; held at a safepoint: a regression fails an assertion, never hangs the run.
(ns suites.blocking-host-calls-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.java.shell :refer [sh]]))

(defn- alloc-loop-ms
  "Force a stop-the-world collection, then allocate enough to trigger more;
  answer the elapsed milliseconds. The explicit `System/gc` makes the
  rendezvous certain whatever the heap threshold is by now."
  []
  (let [t0 (System/currentTimeMillis)]
    (System/gc)
    (dotimes [_ 400] (vec (range 5000)))
    (- (System/currentTimeMillis) t0)))

(defn- detach!
  "Start `argv` as a detached OS process and return at once. A waker outside
  cljw cannot park at a safepoint, so a regression fails the timing assertion
  instead of deadlocking the suite."
  [& argv]
  (apply sh "sh" "-c" "\"$@\" >/dev/null 2>&1 </dev/null &" "detach" argv))

;; A stalled rendezvous would hold the loop until the waker fires (~3 s).
(def ^:private budget-ms 2500)

(deftest accept-on-a-worker
  (testing "a worker blocked in .accept does not stall collections"
    (let [srv (cljw.net/listen "127.0.0.1" 0)
          acc (future (.close (.accept srv)) :accepted)
          _ (detach! "bash" "-c" "sleep 3; exec 3<>/dev/tcp/127.0.0.1/$0" (str (.port srv)))
          _ (Thread/sleep 200)
          took (alloc-loop-ms)]
      (is (< took budget-ms) (str "allocation loop took " took " ms"))
      (is (= :accepted (deref acc 10000 :timeout)))
      (.close srv))))

(deftest read-on-a-worker
  (testing "a worker blocked in .read does not stall collections"
    (let [srv (cljw.net/listen "127.0.0.1" 0)
          _ (detach! "bash" "-c" "exec 3<>/dev/tcp/127.0.0.1/$0; sleep 3; printf abc >&3"
                     (str (.port srv)))
          peer (.accept srv)
          rd (future (.read peer (byte-array 16)))
          _ (Thread/sleep 200)
          took (alloc-loop-ms)]
      (is (< took budget-ms) (str "allocation loop took " took " ms"))
      (is (= 3 (deref rd 10000 :timeout)))
      (.close peer)
      (.close srv))))

(defn- slow-http-peer!
  "Start a child cljw that accepts one HTTP request and answers `ok` three
  seconds later. Answer the port it listens on."
  []
  (let [port-file (str (or (System/getenv "TMPDIR") "/tmp")
                       "/cljw-slow-peer-" (System/currentTimeMillis))
        script (str "(let [s (cljw.net/listen \"127.0.0.1\" 0)]"
                    "  (spit " (pr-str port-file) " (str (.port s)))"
                    "  (let [c (.accept s)]"
                    "    (.read c (byte-array 4096))"
                    "    (Thread/sleep 3000)"
                    "    (.write c (.getBytes (str \"HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\""
                    "                              \"Connection: close\\r\\n\\r\\nok\")))"
                    "    (.close c)))")]
    (detach! "zig-out/bin/cljw" "-e" script)
    (loop [n 0]
      (let [p (try (slurp port-file) (catch Exception _ ""))]
        (cond
          (seq p) (do (sh "rm" "-f" port-file) (Long/parseLong p))
          (< n 200) (do (Thread/sleep 50) (recur (inc n)))
          :else (throw (ex-info "the slow HTTP peer never started" {:port-file port-file})))))))

(deftest http-fetch-on-a-worker
  (testing "a worker waiting on a slow HTTP peer does not stall collections"
    (let [port (slow-http-peer!)
          res (future (cljw.http.client/get (str "http://127.0.0.1:" port "/")))
          _ (Thread/sleep 200)
          took (alloc-loop-ms)]
      (is (< took budget-ms) (str "allocation loop took " took " ms"))
      (is (= {:status 200 :body "ok"} (deref res 10000 :timeout))))))

(deftest http-respond-on-a-worker
  (testing "a server future writing a large response to a slow reader does not stall collections"
    ;; 16 MB fills the loopback socket buffers, so the write blocks until the
    ;; client (another process) starts reading 5 s after it connects.
    (let [port (+ 20000 (rand-int 20000))
          chunk (apply str (repeat 16384 "x"))
          big (apply str (repeat 1024 chunk))
          _srv (future (cljw.http.server/run-server (fn [_] big) {:port port}))
          _ (Thread/sleep 300)
          _ (detach! "bash" "-c"
                     "exec 3<>/dev/tcp/127.0.0.1/$0; printf 'GET / HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n' >&3; sleep 5; cat <&3 >/dev/null"
                     (str port))
          _ (Thread/sleep 800)
          took (alloc-loop-ms)]
      (is (< took budget-ms) (str "allocation loop took " took " ms")))))

(deftest sleep-on-a-worker
  (testing "a sleeping future does not stall collections"
    (let [f (future (Thread/sleep 3000) :slept)
          _ (Thread/sleep 200)
          took (alloc-loop-ms)]
      (is (< took budget-ms) (str "allocation loop took " took " ms"))
      (is (= :slept (deref f 10000 :timeout))))))
