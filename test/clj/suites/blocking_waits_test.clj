;; A worker blocked on one of cljw's own sync objects (a promise, a future, an
;; agent) must count as parked, or a collection the main thread forces
;; deadlocks: the collector waits for the worker, the worker waits for main.
;;
;; The waker is in-process by nature here (only this runtime can deliver the
;; promise), so each case runs in a CHILD cljw bounded by `perl -e alarm`: a
;; regression kills the child and fails the assertion instead of hanging the
;; suite. perl is on every CI runner; GNU `timeout` is not on macOS.
;;
;; Run by `test/clj/run_suites.clj` from the repo root.
(ns suites.blocking-waits-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.java.shell :refer [sh]]
            [clojure.string :as str]))

(defn- run-bounded
  "Run `script` in a child cljw killed after `secs` seconds. => {:exit :out :err}."
  [secs script]
  (sh "perl" "-e" "alarm shift; exec @ARGV" (str secs) "zig-out/bin/cljw" "-e" script))

(defn- gc-while
  "A child program: start `worker` (a form evaluated in a future), let it block,
  force a collection on main, run `after` (the main-thread wake-up, if any), and
  print the worker's result. The collection must not wait for the worker."
  [worker after]
  (str "(let [f (future " worker ") _ (Thread/sleep 200) t0 (System/currentTimeMillis)]"
       "  (System/gc)"
       "  (let [ms (- (System/currentTimeMillis) t0)]"
       "    " after
       "    (println (pr-str {:gc-ms ms :result (deref f 5000 :timeout)}))))"
       "(shutdown-agents)"))

(defn- outcome
  "The child's `{:gc-ms … :result …}` line, read back; nil when the child failed.
  `cljw -e` also prints each top-level form's value, so the line is found by
  its shape, not its position."
  [{:keys [exit out]}]
  (when (zero? exit)
    (some->> (str/split-lines out)
             (filter #(str/starts-with? % "{:gc-ms"))
             first
             read-string)))

(deftest deref-promise-on-a-worker
  (testing "main delivers only after its collection: a stall here is a deadlock"
    (let [r (run-bounded 20 (str "(def p (promise))"
                                 (gc-while "(deref p)" "(deliver p :ok)")))]
      (is (zero? (:exit r)) (str "child exited " (:exit r) " (142 = killed by the alarm): " (:err r)))
      (is (= :ok (:result (outcome r)))))))

(deftest deref-promise-with-timeout-on-a-worker
  (testing "a timed deref is a wait too: the collection must not sit out the timeout"
    (let [r (run-bounded 20 (gc-while "(deref (promise) 3000 :late)" ""))
          {:keys [gc-ms result]} (outcome r)]
      (is (zero? (:exit r)) (str (:err r)))
      (is (= :late result))
      (is (< gc-ms 2000) (str "collection took " gc-ms " ms")))))

(deftest deref-future-on-a-worker
  (testing "a future waiting on another future's result"
    (let [r (run-bounded 20 (str "(def g (future (Thread/sleep 1500) :slept))"
                                 (gc-while "(deref g)" "")))]
      (is (zero? (:exit r)) (str "child exited " (:exit r) ": " (:err r)))
      (is (= :slept (:result (outcome r)))))))

(deftest await-agent-on-a-worker
  (testing "a future awaiting an agent whose action is still running"
    (let [r (run-bounded 20 (str "(def a (agent 0))"
                                 (gc-while "(do (send a (fn [x] (Thread/sleep 1500) (inc x))) (await a) @a)" "")))]
      (is (zero? (:exit r)) (str "child exited " (:exit r) ": " (:err r)))
      (is (= 1 (:result (outcome r)))))))

(deftest realized?-on-a-delay-being-forced
  (testing "main forces a delay whose thunk collects; a worker asks (realized? d) meanwhile"
    ;; realized? reads the state without the once-lock, so mid-force it answers
    ;; false at once. Before the fix it waited on the lock and never answered.
    (let [r (run-bounded 20 (str "(def d (delay (Thread/sleep 300) (System/gc) :forced))"
                                 "(def f (future (Thread/sleep 100) (realized? d)))"
                                 "(println (pr-str {:gc-ms 0 :result [@d (deref f 5000 :timeout)]}))"
                                 "(shutdown-agents)"))]
      (is (zero? (:exit r)) (str "child exited " (:exit r) " (142 = killed by the alarm): " (:err r)))
      (is (= [:forced false] (:result (outcome r))))))
  (testing "a delay's own thunk may ask whether it is realised"
    (let [r (run-bounded 20 (str "(def d (delay (realized? d)))"
                                 "(println (pr-str {:gc-ms 0 :result @d}))"))]
      (is (zero? (:exit r)) (str "child exited " (:exit r) ": " (:err r)))
      (is (= false (:result (outcome r)))))))

(deftest idle-thread-pool
  (testing "an idle executor worker waits for work at a safepoint: the first collection after the pool idles"
    (let [r (run-bounded 20 (str "(def pool (java.util.concurrent.Executors/newFixedThreadPool 2))"
                                 "(def v (.get (.submit pool (fn [] :ran))))"
                                 "(Thread/sleep 200)"
                                 "(System/gc)"
                                 "(println (pr-str {:gc-ms 0 :result v}))"
                                 "(.shutdown pool)"))]
      (is (zero? (:exit r)) (str "child exited " (:exit r) " (142 = killed by the alarm): " (:err r)))
      (is (= :ran (:result (outcome r)))))))

(deftest join-thread-on-a-worker
  (testing "a future joining a Thread"
    (let [r (run-bounded 20 (str "(def t (Thread. (fn [] (Thread/sleep 1500))))"
                                 "(.start t)"
                                 (gc-while "(do (.join t) :joined)" "")))]
      (is (zero? (:exit r)) (str "child exited " (:exit r) ": " (:err r)))
      (is (= :joined (:result (outcome r)))))))

(deftest deref-ref-while-a-commit-collects
  (testing "a worker reading @r spins on the ref's commit lock while main's commit runs a collecting commute fn"
    (let [r (run-bounded 20 (str "(def r (ref 0))"
                                 "(def stop (atom false))"
                                 "(def f (future (loop [n 0] (if @stop n (do @r (recur (inc n)))))))"
                                 "(Thread/sleep 100)"
                                 "(dosync (commute r (fn [x] (System/gc) (inc x))))"
                                 "(reset! stop true)"
                                 "(println (pr-str {:gc-ms 0 :result [@r (pos? (deref f 5000 -1))]}))"
                                 "(shutdown-agents)"))]
      (is (zero? (:exit r)) (str "child exited " (:exit r) ": " (:err r)))
      (is (= [1 true] (:result (outcome r)))))))

(deftest queue-spin-while-contains-collects
  (testing "a worker spinning on a LinkedBlockingQueue lock that main holds across a collecting ="
    (let [r (run-bounded 20 (str "(deftype K [] Object (equals [_ _] (System/gc) false) (hashCode [_] 1))"
                                 "(def q (java.util.concurrent.LinkedBlockingQueue.))"
                                 "(.offer q 1)"
                                 "(def stop (atom false))"
                                 "(def f (future (loop [n 0] (if @stop n (do (.size q) (recur (inc n)))))))"
                                 "(Thread/sleep 100)"
                                 "(def hit (.contains q (K.)))"
                                 "(reset! stop true)"
                                 "(println (pr-str {:gc-ms 0 :result [hit (pos? (deref f 5000 -1))]}))"
                                 "(shutdown-agents)"))]
      (is (zero? (:exit r)) (str "child exited " (:exit r) ": " (:err r)))
      (is (= [false true] (:result (outcome r)))))))
