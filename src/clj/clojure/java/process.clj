;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/src/clj/clojure/java/process.clj
;; Upstream lines: 196
;; CLJW markers: 7

;; CLJW: CW-native implementation. No ProcessBuilder, streams, or thread pools.
;; Synchronous process execution via clojure.java.shell/sh.

(ns clojure.java.process
  "A process invocation API wrapping the Java process API.

   The primary function is 'start' which starts a process and handles the
   streams as directed. It returns a process result map. Use 'exit-ref' to
   get the exit value, and 'stdout', 'stderr' to access captured output.
   The 'exec' function handles the common case to 'start' a process,
   wait for process exit, and return stdout."
  ;; CLJW: no Java imports, uses clojure.java.shell/sh
  (:require [clojure.java.shell :as shell]))

;; CLJW: no null-file, to-file, from-file (require ProcessBuilder.Redirect)

(defn start
  "Start an external command, defined in args.

  If needed, provide options in map as first arg:
    :dir - current directory when the process runs (default=\".\")
    :env - {env-var value} of environment variables to set (all strings)

  Returns a process result map with :exit, :out, :err."
  ;; CLJW: synchronous execution via sh. No :in/:out/:err redirect, :clear-env.
  {:added "1.12"}
  [& opts+args]
  (let [[opts command] (if (map? (first opts+args))
                         [(first opts+args) (rest opts+args)]
                         [{} opts+args])
        {:keys [dir]} opts
        sh-args (if dir
                  (concat command [:dir dir])
                  command)]
    (apply shell/sh sh-args)))

(defn stdout
  "Given a process result, return the stdout output string."
  {:added "1.12"}
  [process]
  (:out process))

(defn stderr
  "Given a process result, return the stderr output string."
  {:added "1.12"}
  [process]
  (:err process))

;; CLJW: stdin not supported (process already completed)

(defn exit-ref
  "Given a process result (the output of 'start'), return a reference that
  can be deref'd to get the exit value."
  {:added "1.12"}
  [process]
  ;; CLJW: return a delay wrapping the exit code (process already completed)
  (let [exit-val (:exit process)]
    (delay exit-val)))

;; CLJW: no io-thread-factory, io-executor, io-task (no threading)

(defn exec
  "Execute a command and on successful exit, return the captured output,
  else throw an exception. Args are the same as 'start' and options
  if supplied override the default 'exec' settings."
  {:added "1.12"}
  [& opts+args]
  (let [proc (apply start opts+args)
        exit (:exit proc)]
    (if (zero? exit)
      (:out proc)
      ;; CLJW: ex-info instead of RuntimeException
      (throw (ex-info (str "Process failed with exit=" exit) {:exit exit :err (:err proc)})))))
