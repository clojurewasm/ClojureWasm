;; STM, Thread lifecycle, watch/validator re-entry overflow, System properties,
;; filesystem require and Var source meta (Phase B #5 / AD-013, ADR-0174 D6,
;; ADR-0157 / D-485 / D-486, D-158 / ADR-0084 / ADR-0189, D-563b / D-316).
;;
;; Migrated from the phase15 e2e scripts stm_dosync, thread_lifecycle,
;; watch_recursion, system_property, require_fs and var_source_meta. What
;; still needs a process stays in those scripts, each marked
;; e2e-process-boundary: join-at-exit and daemon-no-wait (process EXIT),
;; the no-SIGSEGV exit codes, env vars / -cp / CLJW_PATH argv, and the AOT
;; `cljw build` artifact.
(ns suites.concurrency-host-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.java.io :as io]
            [clojure.string :as str]))

(deftest p15-stm-dosync
  (testing "phase15_stm_dosync single-thread"
    (is (= 42 (let [r (ref 0)] (dosync (ref-set r 42)) @r)) "dosync_ref_set")
    (is (= 5 (let [r (ref 0)] (dosync (alter r + 5)) @r)) "dosync_alter")
    (is (= 22 (let [r (ref 10)] (dosync (alter r + 1) (alter r * 2)) @r)) "dosync_sees_own_writes")
    (is (= 6 (let [r (ref 0)] (dosync (ref-set r 5) (alter r inc)) @r)) "dosync_in_txn_read")
    (is (= 2 (let [r (ref 0)] (dosync (alter r inc) (dosync (alter r inc))) @r)) "dosync_nested")
    (is (= [10 20] (let [a (ref 1) b (ref 2)] (dosync (ref-set a 10) (ref-set b 20)) [@a @b])) "dosync_multi_ref")
    (is (= 5 (let [r (ref 0)] (dosync (commute r + 5)) @r)) "dosync_commute")
    (is (= [2 15] (let [a (ref 1) b (ref 10)] (dosync (alter a inc) (commute b + 5)) [@a @b])) "dosync_alter_plus_commute")
    (is (= [1 3] (let [a (ref 1) b (ref 2)] (dosync (ensure a) (alter b + (deref a))) [@a @b])) "dosync_ensure"))
  (testing "concurrency (AD-013: retry, no barge)"
    (is (= [0 200] (let [a (ref 0) b (ref 0)]
                     (run! deref (mapv (fn [_] (future (dotimes [_ 50] (dosync (ensure a) (alter b inc))))) (range 4)))
                     [@a @b])) "dosync_concurrent_ensure")
    (is (= 400 (let [c (ref 0)]
                 (run! deref (mapv (fn [_] (future (dotimes [_ 100] (dosync (alter c inc))))) (range 4)))
                 @c)) "dosync_concurrent_serializable")
    (is (= [-100 200] (let [a (ref 100) b (ref 0)]
                        (run! deref (mapv (fn [_] (future (dotimes [_ 50] (dosync (alter a dec) (alter b inc))))) (range 4)))
                        [@a @b])) "dosync_concurrent_multi_ref_transfer")
    (is (= 400 (let [c (ref 0)]
                 (run! deref (mapv (fn [_] (future (dotimes [_ 100] (dosync (commute c inc))))) (range 4)))
                 @c)) "dosync_concurrent_commute"))
  (testing "errors / abort"
    (is (thrown-with-msg? Throwable #"must be called inside a \(dosync" (alter (ref 0) inc)) "alter_out_of_txn_errors")
    (is (= 1 (let [r (ref 1)] (try (dosync (ref-set r 2) (throw (ex-info "x" {}))) (catch Throwable e :c)) @r)) "dosync_abort_on_throw"))
  (testing "ref watches"
    (is (= [[0 2]] (let [log (atom []) r (ref 0)]
                     (add-watch r :k (fn [k rf o n] (swap! log conj [o n])))
                     (dosync (alter r inc) (alter r inc)) @log)) "ref_add_watch_net")
    (is (= [] (let [log (atom []) r (ref 0)]
                (add-watch r :k (fn [k rf o n] (swap! log conj n)))
                (dosync @r) @log)) "ref_watch_readonly_silent")
    (is (= [1] (let [log (atom []) r (ref 0)]
                 (add-watch r :k (fn [k rf o n] (swap! log conj n)))
                 (dosync (alter r inc)) (remove-watch r :k) (dosync (alter r inc)) @log)) "ref_remove_watch")
    (is (= [[:a 1] [:b 11]] (let [log (atom []) a (ref 0) b (ref 10)]
                              (add-watch a :a (fn [k r o n] (swap! log conj [:a n])))
                              (add-watch b :b (fn [k r o n] (swap! log conj [:b n])))
                              (dosync (alter a inc) (alter b inc))
                              (vec (sort-by second @log)))) "ref_watch_multi")))

(deftest p15-thread-lifecycle
  (testing "phase15_thread_lifecycle"
    (is (= "Hello from thread\n"
           (with-out-str (let [w *out* t (Thread. (fn [] (binding [*out* w] (println "Hello from thread"))))] (.start t) (.join t))))
        "ctor_start_join")
    (is (boolean (re-find #"^Thread-\d+$" (.getName (Thread. (fn []))))) "auto_name")
    (is (= "worker-1" (.getName (Thread. (fn []) "worker-1"))) "ctor_name")
    (is (= "renamed" (let [t (Thread. (fn []))] (.setName t "renamed") (.getName t))) "set_name")
    (is (= "inner" (let [seen (promise)
                         t (Thread. (fn [] (deliver seen (.getName (Thread/currentThread)))) "inner")]
                     (.start t) (.join t) @seen)) "current_thread_inside")
    (is (= "main" (.getName (Thread/currentThread))) "main_thread_name")
    (is (= [false true false] (let [t (Thread. (fn [] (Thread/sleep 100)))
                                    a (.isAlive t) _ (.start t) b (.isAlive t) _ (.join t)]
                                [a b (.isAlive t)])) "is_alive")
    (is (thrown-with-msg? Throwable #"already started"
          (let [t (Thread. (fn []))] (.start t) (.join t) (.start t))) "double_start")
    (is (= [true false] (let [t (Thread. (fn [] (Thread/sleep 300)) "slow")]
                          (.start t) (.join t 30)
                          (let [a (.isAlive t)] (.join t) [a (.isAlive t)]))) "timed_join")
    (is (= [false true] (let [t (Thread. (fn []))]
                          (let [a (.isDaemon t)] (.setDaemon t true) [a (.isDaemon t)]))) "daemon_flag")
    (let [t (Thread. (fn [] (Thread/sleep 50)))]
      (.start t)
      (is (thrown-with-msg? Throwable #"already started" (.setDaemon t true)) "setdaemon_after_start")
      (.join t))
    (is (= [nil nil] [(Thread/yield) (Thread/onSpinWait)]) "yield_spin")
    (is (= [1 5 10] [Thread/MIN_PRIORITY Thread/NORM_PRIORITY Thread/MAX_PRIORITY]) "priorities")
    (is (= "java.lang.Thread" (str (class (Thread. (fn []))))) "thread_class")
    (is (instance? Thread (Thread. (fn []))) "thread_instance")))

(deftest p15-watch-recursion
  (let [wrec #(let [a (atom 0)] (add-watch a :w (fn [k r o n] (swap! r inc))) (swap! a inc))]
    (testing "phase15_watch_recursion: runaway re-entry is a catchable StackOverflowError (ADR-0157)"
      (is (thrown-with-msg? StackOverflowError #"Stack overflow" (wrec)) "watch_recursion_graceful / catch_as_stackoverflow")
      (is (= :caught (try (wrec) (catch Throwable e :caught))) "catch_as_throwable")
      (is (= :as-thr (try (wrec) (catch Exception e :as-exc) (catch Throwable e :as-thr))) "catch_not_as_exception")
      (is (= :caught (try (let [a (atom 0)] (set-validator! a (fn [n] (swap! a inc) true)) (reset! a 5))
                          (catch StackOverflowError e :caught))) "validator_reentry_caught")
      (is (= :caught (try (reduce (fn f [acc x] (reduce f acc [x])) 0 [1 2 3]) (catch Throwable e :caught))) "reducer_reentry_caught")
      (is (= :caught (try ((fn f [n] (f (inc n))) 0) (catch StackOverflowError e :caught))) "direct_recursion_caught")
      (is (= :caught (try ((fn f [n] (f (inc n))) 0) (catch Throwable e :caught))) "direct_recursion_thr"))
    (testing "legit chains / bounded recursion are untouched"
      (is (= [1 10] (let [a (atom 0) b (atom 0)]
                      (add-watch a :w (fn [k r o n] (reset! b (* 10 n))))
                      (swap! a inc) [@a @b])) "legit_watch_chain")
      (is (= [2] (let [a (atom 0) b (atom 0) log (atom [])]
                   (add-watch a :wa (fn [k r o n] (reset! b (inc n))))
                   (add-watch b :wb (fn [k r o n] (swap! log conj n)))
                   (swap! a inc) @log)) "two_level_watch")
      ;; depths are the script's tree_walk-safe values (D-555): the suite runs
      ;; on whichever backend the binary was built with.
      (is (= :done ((fn f [n] (if (zero? n) :done (first (map (fn [_] (f (dec n))) [1])))) 100)) "legit_hof_recursion")
      (is (= :done ((fn f [n] (if (zero? n) :done (f (dec n)))) 300)) "legit_direct_recursion"))))

(deftest p15-system-property
  (testing "phase15_system_property (process-independent cases)"
    (is (= "\n" (System/getProperty "line.separator")) "line-sep")
    (is (= ":" (System/getProperty "path.separator")) "path-sep")
    (is (= "/" (System/getProperty "file.separator")) "file-sep")
    (is (= "UTF-8" (System/getProperty "file.encoding")) "encoding")
    (is (string? (System/getProperty "os.name")) "os-name")
    (is (string? (System/getProperty "os.arch")) "os-arch")
    (is (string? (System/getProperty "user.dir")) "user-dir")
    (is (nil? (System/getProperty "no.such.prop.xyz")) "unknown")
    (is (= "fallback" (System/getProperty "no.such.prop.xyz" "fallback")) "default")
    (is (= "/" (java.lang.System/getProperty "file.separator")) "fqcn")
    (is (nil? (System/getenv "CLJW_DEFINITELY_UNSET_XYZ")) "getenv-missing")))

(defn- tmp-root []
  (let [d (io/file (System/getProperty "java.io.tmpdir") (str "cljw-p15-" (System/nanoTime) "-" (rand-int 1000000)))]
    (.mkdirs d)
    d))

(defn- spit-in [root rel text]
  (let [f (io/file root rel)]
    (.mkdirs (.getParentFile f))
    (spit f text)))

(defn- delete-tree [f]
  (when (.isDirectory f) (run! delete-tree (.listFiles f)))
  (.delete f))

(deftest p15-require-fs
  ;; -cp / CLJW_PATH roots are argv / environment (they stay in
  ;; test/e2e/phase15_require_fs.sh); these cases load through
  ;; clojure.core/load-file, which shares the on-disk loader.
  (testing "phase15_require_fs: a disk test-ns requiring clojure.test + a disk lib"
    (load-file "test/e2e/fixtures/cljwlib/demo/math.clj")
    (load-file "test/e2e/fixtures/cljwlib/demo/math_test.clj")
    (is (= 49 ((ns-resolve 'demo.math 'square) 7)) "cp-load")
    (is (= 64 ((ns-resolve 'demo.math 'cube) 4)) "env-path")
    (let [s (binding [clojure.test/*test-out* (java.io.StringWriter.)
                      clojure.test/*report-counters* nil
                      clojure.test/*testing-vars* (list)
                      clojure.test/*testing-contexts* (list)]
              (clojure.test/run-tests 'demo.math-test))]
      (is (= [4 0] [(:pass s) (:fail s)]) "run-suite")))
  (testing "missing lib"
    (is (thrown-with-msg? Throwable #"Could not locate" (require 'p15.no.such.fs.lib)) "missing")))

(deftest p15-var-source-meta
  (let [ev (fn [src] (binding [*ns* (create-ns (gensym "p15.vsm"))]
                       (refer 'clojure.core)
                       (load-string src)))]
    (testing "phase15_var_source_meta"
      (is (= [1 true 2] (ev "(def a 1)\n(defn f [x] x)\n[(:line (meta (var a))) (pos? (:column (meta (var a)))) (:line (meta (var f)))]")) "line_col")
      (is (true? (ev "(def a 1)\n(string? (:file (meta (var a))))")) "file_is_label")
      (is (= ["gdoc" "me"] (ev "(defn g \"gdoc\" {:author \"me\"} [x] x)\n[(:doc (meta (var g))) (:author (meta (var g)))]")) "doc_and_user_meta")
      (is (= [1 "me"] (ev "(def ^{:line 999 :author \"me\"} h 1)\n[(:line (meta (var h))) (:author (meta (var h)))]")) "compiler_line_wins")
      (is (= [3 '(a b) "s"] (ev "(def ^{:computed (+ 1 2) :quoted (quote (a b)) :lit \"s\"} mv 1)\n[(:computed (meta (var mv))) (:quoted (meta (var mv))) (:lit (meta (var mv)))]")) "computed_meta")
      (is (= [6 '([x])] (ev "(defn mf \"d\" {:extra (* 2 3)} [x] x)\n[(:extra (meta (var mf))) (:arglists (meta (var mf)))]")) "defn_attr_computed"))
    (testing "fixture file: :file is the real path, :line the real line"
      (let [root (tmp-root)]
        (try
          (spit-in root "src_meta_fix.clj" "(ns p15.src-meta-fix)\n(defn fixture-fn [x] x)\n")
          (load-file (str (io/file root "src_meta_fix.clj")))
          (let [m (meta (ns-resolve 'p15.src-meta-fix 'fixture-fn))]
            (is (= 2 (:line m)) "fixture_line_file: line")
            (is (str/includes? (str (:file m)) "src_meta_fix") "fixture_line_file: file"))
          (finally (delete-tree root)))))))
