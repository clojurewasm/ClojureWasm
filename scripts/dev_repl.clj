#!/usr/bin/env bb
;; scripts/dev_repl.clj — the cljw dev loop, in Clojure instead of bash.
;;
;; Runs under babashka. The protocol half (bencode + the nREPL exchange) lives
;; in scripts/dev/*.cljc and is SHARED with cljw — the same client code runs on
;; both runtimes, so using the loop dogfoods cljw's own socket/byte/UTF-8 stack:
;;
;;     bb  scripts/dev_repl.clj eval '(+ 1 2)'      # this file
;;     echo '(+ 1 2)' | CLJW_REPL_PORT=7899 \
;;         zig-out/bin/cljw scripts/nrepl_client.clj   # same .cljc, under cljw
;;
;; Babashka owns only the part cljw genuinely cannot express today: process
;; supervision. cljw has no process-spawn surface at all (no
;; clojure.java.shell/sh, no ProcessBuilder, no cljw.process), so start/stop
;; live here. If cljw grows that surface, this file can move over too.
;;
;; WHAT THE LOOP IS FOR (measured 2026-08-30, quiet machine, warm cache):
;;   redefine a var over nREPL ................... 0.13 s
;;   the same change through core.clj ............ ~400 s   (full bytecode regen)
;;   a .zig change (dual-backend test binaries) .. ~400-590 s
;; So: work out WHAT a clojure.core definition should be here — a `defn` in the
;; running image shadows the embedded one — then edit core.clj and pay the
;; rebuild ONCE.
;;
;; It is NOT for running the suites: cljw cold-starts in ~21 ms, which beats any
;; warm-image round trip. Run those directly:
;;     zig-out/bin/cljw -cp test/clj:scripts test/clj/run_suites.clj
;;
;; Usage:
;;   bb scripts/dev_repl.clj start|stop|status
;;   bb scripts/dev_repl.clj eval '(+ 1 2)'
;;   echo '(defn f [] 1)' | bb scripts/dev_repl.clj eval -
;;   bb scripts/dev_repl.clj test [suite-ns]
(ns dev-repl
  (:require [babashka.process :as p]
            [clojure.string :as str]
            [dev.nrepl :as nrepl]))

(def port (Integer/parseInt (or (System/getenv "CLJW_REPL_PORT") "7899")))
(def host (or (System/getenv "CLJW_REPL_HOST") "127.0.0.1"))
(def bin "zig-out/bin/cljw")
(def logfile ".dev/.dev_repl.log")

(defn- pgrep-pattern []
  ;; Match the server itself, scoped to THIS port. Reaping by the shell's $! is
  ;; the trap the orphan rules call out: the server is a grandchild through
  ;; `timeout`, so killing the parent orphans the runtime instead of reaping it.
  (str "nrepl --port " port))

(defn- server-pids []
  (->> (:out (p/shell {:out :string :continue true} "pgrep" "-f" (pgrep-pattern)))
       str/split-lines
       (remove str/blank?)
       vec))

(defn- running? [] (seq (server-pids)))

(defn- start! []
  (if (running?)
    (println (str "already running on port " port))
    (do
      (when-not (.exists (java.io.File. bin))
        (println (str "no " bin " — build first: zig build -Dwasm -Doptimize=ReleaseSafe"))
        (System/exit 1))
      (.mkdirs (java.io.File. ".dev"))
      ;; `timeout` bounds the server so an abandoned session cannot outlive the
      ;; day; :out :inherit would tie it to this process, so it goes to a file.
      (p/process ["timeout" "3600" bin "nrepl" "--port" (str port) "-cp" "test/clj"]
                 {:out (java.io.File. logfile) :err :out})
      (loop [tries 40]
        (cond
          (running?) (do (Thread/sleep 800)
                         (println (str "cljw nREPL up on " port " (log: " logfile ")")))
          (zero? tries) (do (println (str "failed to start; see " logfile)) (System/exit 1))
          :else (do (Thread/sleep 250) (recur (dec tries))))))))

(defn- stop! []
  (p/shell {:continue true :out :string :err :string} "pkill" "-f" (pgrep-pattern))
  (println (str "reaped any nREPL on port " port)))

(defn- require-server! []
  (when-not (running?)
    (println "not running — bb scripts/dev_repl.clj start")
    (System/exit 1)))

(defn- send! [code]
  (require-server!)
  (let [conn (nrepl/connect host port)
        failed (nrepl/print-responses (nrepl/eval-code conn code))]
    (nrepl/close conn)
    (System/exit (if failed 1 0))))

(defn -main [& args]
  (let [[cmd arg] args]
    (case cmd
      "start"  (start!)
      "stop"   (stop!)
      "status" (if (running?)
                 (println (str "up on " port " (pids " (str/join "," (server-pids)) ")"))
                 (println (str "not running on " port)))
      "eval"   (send! (if (= arg "-") (slurp *in*) (or arg "")))
      "test"   (if arg
                 (send! (str "(do (require 'clojure.test) (require '" arg " :reload)"
                             " (clojure.test/run-tests '" arg "))"))
                 ;; No ns given: run every suite the way the gate does — one
                 ;; cold cljw process, which is faster than the warm round trip.
                 (let [r (p/shell {:continue true} bin "-cp" "test/clj:scripts" "test/clj/run_suites.clj")]
                   (System/exit (:exit r))))
      (do (println (str/join "\n" ["usage: bb scripts/dev_repl.clj <cmd>"
                                   "  start | stop | status"
                                   "  eval '<code>' | eval -   (code on stdin)"
                                   "  test [suite-ns]"]))
          (System/exit 1)))))

(apply -main *command-line-args*)
