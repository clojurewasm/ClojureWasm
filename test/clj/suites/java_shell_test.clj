;; clojure.java.shell parity over the native cljw.process/run (ADR-0199).
;;
;; Run by `test/clj/run_suites.clj`. Uses only POSIX tools present on every CI
;; runner (sh, cat, pwd, env, printf), started by argv, never through a shell
;; string built by the test.
(ns suites.java-shell-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.string :as str]
            [clojure.java.shell :refer [sh with-sh-dir with-sh-env]]))

(deftest exit-is-data
  (testing "a zero exit carries stdout and an empty stderr"
    (is (= {:exit 0 :out "hello world\n" :err ""} (sh "printf" "hello world\\n"))))
  (testing "a non-zero exit is returned, not thrown, with both streams"
    (is (= {:exit 3 :out "out\n" :err "err\n"}
           (sh "sh" "-c" "echo out; echo err >&2; exit 3"))))
  (testing "a child killed by signal N reports 128+N"
    (is (= 137 (:exit (sh "sh" "-c" "kill -9 $$"))))))

(deftest stdin
  (is (= "piped text" (:out (sh "cat" :in "piped text"))))
  (testing "an :in far larger than a pipe buffer does not deadlock"
    (let [big (apply str (repeat 200000 "x"))]
      (is (= 200000 (count (:out (sh "cat" :in big))))))))

(deftest directory
  (is (= "/" (str/trim (:out (sh "pwd" :dir "/")))))
  (is (= "/" (str/trim (:out (with-sh-dir "/" (sh "pwd"))))))
  (testing "an explicit :dir wins over the binding"
    (is (= "/" (str/trim (:out (with-sh-dir "/no/such/dir" (sh "pwd" :dir "/"))))))))

;; /usr/bin/env by path: a bare `env` resolves through the caller's PATH, which
;; on a developer machine may shadow it with a sourced-only script.
(deftest environment
  (testing "without :env the child inherits the parent environment"
    (is (= (System/getenv "PATH")
           (:out (sh "sh" "-c" "printf '%s' \"$PATH\"")))))
  (testing ":env replaces the inherited environment; keys may be keywords, values are stringified"
    (let [lines (set (str/split-lines (:out (sh "/usr/bin/env" :env {"FOO" "bar" :N 42}))))]
      (is (contains? lines "FOO=bar"))
      (is (contains? lines "N=42"))
      (is (not-any? #(str/starts-with? % "PATH=") lines))))
  (testing "the program is still found on the PARENT's PATH when :env replaces it"
    (is (= "x" (:out (sh "printf" "x" :env {"X" "1"})))))
  (testing "a seq of NAME=value strings, through the binding"
    (is (contains? (set (str/split-lines (:out (with-sh-env ["A=1=2"] (sh "/usr/bin/env")))))
                   "A=1=2")))
  (testing "an invalid variable name is a catchable error, not a crash"
    (is (thrown? Exception (sh "printf" "x" :env {"A=B" "1"})))
    (is (thrown? Exception (sh "printf" "x" :env {"" "1"})))))

(deftest child-ignores-stdin
  (testing "a child that exits without reading a large :in does not kill cljw (SIGPIPE)"
    (is (= 0 (:exit (sh "true" :in (apply str (repeat 1000000 "y"))))))))

(deftest restrictions
  (testing "run is refused inside a with-budget extent: a child would escape the budget"
    (is (str/includes? (try (cljw.eval/with-budget {:deadline-ms 60000} #(sh "true"))
                            (catch Exception e (ex-message e)))
                       "with-budget"))))

(deftest worker-thread
  (testing "a sh on a future does not stall collections the main thread triggers"
    (let [f (future (sh "sh" "-c" "sleep 3; printf done"))
          _ (Thread/sleep 200)
          t0 (System/currentTimeMillis)
          _ (dotimes [_ 400] (vec (range 5000)))
          took (- (System/currentTimeMillis) t0)]
      ;; A stalled rendezvous would hold the loop until the child exits (~3 s).
      (is (< took 2500) (str "allocation loop took " took " ms"))
      (is (= "done" (:out (deref f 10000 :timeout)))))))

(deftest output-encoding
  (let [b (:out (sh "printf" "ab" :out-enc :bytes))]
    (is (= [97 98] (vec b))))
  (is (thrown? IllegalArgumentException (sh "printf" "x" :out-enc "latin1")))
  (is (thrown? IllegalArgumentException (sh "printf" "x" :in-enc "latin1"))))

(deftest refusals
  (testing "a program the host cannot start throws, naming the program"
    (is (str/includes? (try (sh "cljw-no-such-program-x") (catch Exception e (ex-message e)))
                       "cljw-no-such-program-x")))
  (testing "a missing :dir is a start failure too"
    (is (thrown? Exception (sh "pwd" :dir "/no/such/dir"))))
  (testing "argument shape"
    (is (thrown? IllegalArgumentException (sh :in "x")))
    (is (thrown? IllegalArgumentException (sh "printf" :in)))
    (is (thrown? Exception (cljw.process/run [])))
    (is (thrown? Exception (cljw.process/run ["printf" 1])))))

(deftest raw-substrate
  (is (= {:exit 0 :out "raw" :err ""} (cljw.process/run ["printf" "raw"]))))
