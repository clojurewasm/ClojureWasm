;; Copyright (c) Rich Hickey All rights reserved. The use and
;; distribution terms for this software are covered by the Eclipse Public
;; License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can be found
;; in the file epl-v10.html at the root of this distribution. By using this
;; software in any fashion, you are agreeing to be bound by the terms of
;; this license. You must not remove this notice, or any other, from this
;; software.

;; Upstream: clojure/src/clj/clojure/main.clj
;; Upstream lines: 676
;; CLJW markers: 19

;; CLJW: CW-native implementation. No Compiler, RT, LineNumberingPushbackReader,
;; DynamicClassLoader, Thread, or stack trace analysis.

(ns ^{:doc "Top-level main function for Clojure REPL and scripts."
      :author "Stephen C. Gilardi and Rich Hickey"}
 clojure.main
  (:refer-clojure :exclude [with-bindings])
  (:require [clojure.string]))

;; CLJW: no Java imports

(declare main)

;;;;;;;;;;;;;;;;;;; error helpers ;;;;;;;;;;;;;;

;; CLJW: simplified demunge — CW doesn't munge fn names
(defn demunge
  "Given a string representation of a fn class,
  as in a stack trace element, returns a readable version."
  {:added "1.3"}
  [fn-name]
  fn-name)

;; CLJW: simplified root-cause — no CompilerException unwrapping
(defn root-cause
  "Returns the initial cause of an exception or error by peeling off all of
  its wrappers"
  {:added "1.3"}
  [t]
  (loop [cause t]
    (if-let [c (ex-cause cause)]
      (recur c)
      cause)))

(defn stack-element-str
  "Returns a string representation of a stack trace element"
  {:added "1.3"}
  ;; CLJW: CW doesn't have Java stack trace elements
  [el]
  (str el))

;;;;;;;;;;;;;;;;;;; end of error helpers ;;;;;;;;;;;;;;

;; CLJW: simplified with-bindings — CW dynamic vars only
(defmacro with-bindings
  "Executes body in the context of thread-local bindings for several vars
  that often need to be set!: *ns* *print-meta* *print-length* *print-level*
  *command-line-args* *1 *2 *3 *e"
  [& body]
  ;; CLJW: only CW dynamic vars (*1/*2/*3/*e/*assert* not dynamic in CW)
  `(binding [*ns* *ns*
             *print-meta* *print-meta*
             *print-length* *print-length*
             *print-level* *print-level*
             *data-readers* *data-readers*
             *default-data-reader-fn* *default-data-reader-fn*
             *command-line-args* *command-line-args*]
     ~@body))

(defn repl-prompt
  "Default :prompt hook for repl"
  []
  (printf "%s=> " (ns-name *ns*)))

;; CLJW: no skip-if-eol, skip-whitespace, renumbering-read (require pushback reader)

;; CLJW: simplified repl-read — reads from *in* via read
(defn repl-read
  "Default :read hook for repl. Reads from *in*."
  [request-prompt request-exit]
  (let [input (read {:eof request-exit} *in*)]
    input))

(defn repl-exception
  "Returns the root cause of throwables"
  [throwable]
  (root-cause throwable))

(defn- file-name
  "Helper to get just the file name part of a path or nil"
  [full-path]
  (when full-path
    (let [idx (max (.lastIndexOf ^String full-path "/")
                   (.lastIndexOf ^String full-path "\\"))]
      (if (neg? idx) full-path (subs full-path (inc idx))))))

(defn- file-path
  "Helper to get the relative path to the source file or nil"
  [full-path]
  full-path)

;; CLJW: simplified ex-triage — no JVM stack trace analysis
(defn ex-triage
  "Returns an analysis of the phase, error, cause, and location of an error that occurred
  based on Throwable data, as returned by Throwable->map. All attributes other than phase
  are optional:
    :clojure.error/phase - keyword phase indicator
    :clojure.error/source - file name (no path)
    :clojure.error/line - integer line number
    :clojure.error/column - integer column number
    :clojure.error/symbol - symbol being expanded/compiled/invoked
    :clojure.error/class - cause exception class symbol
    :clojure.error/cause - cause exception message"
  {:added "1.10"}
  [datafied-throwable]
  (let [{:keys [via phase] :or {phase :execution}} datafied-throwable
        {:keys [type message data]} (last via)
        {:clojure.error/keys [source] :as top-data} (:data (first via))]
    ;; CLJW: cond instead of case (CW case macro limitation)
    (assoc
     (cond
       (= phase :read-source)
       (cond-> (merge (-> via second :data) top-data)
         source (assoc :clojure.error/source (file-name source)
                       :clojure.error/path (file-path source))
         message (assoc :clojure.error/cause message))

       (#{:compile-syntax-check :compilation :macro-syntax-check :macroexpansion} phase)
       (cond-> top-data
         source (assoc :clojure.error/source (file-name source)
                       :clojure.error/path (file-path source))
         type (assoc :clojure.error/class type)
         message (assoc :clojure.error/cause message))

       (#{:read-eval-result :print-eval-result} phase)
       (cond-> top-data
         type (assoc :clojure.error/class type)
         message (assoc :clojure.error/cause message))

       :else
       (cond-> {:clojure.error/class type}
         message (assoc :clojure.error/cause message)))
     :clojure.error/phase phase)))

(defn ex-str
  "Returns a string from exception data, as produced by ex-triage.
  The first line summarizes the exception phase and location.
  The subsequent lines describe the cause."
  {:added "1.10"}
  [{:clojure.error/keys [phase source path line column symbol class cause spec]
    :as triage-data}]
  (let [loc (str (or path source "REPL") ":" (or line 1) (if column (str ":" column) ""))
        class-name (if class (name class) "")
        simple-class (if class (or (last (clojure.string/split class-name #"\.")) class-name))
        cause-type (if (#{"Exception" "RuntimeException"} simple-class)
                     ""
                     (str " (" simple-class ")"))]
    ;; CLJW: cond instead of case (CW case macro limitation)
    (cond
      (= phase :read-source)
      (format "Syntax error reading source at (%s).\n%s\n" loc cause)

      (= phase :macro-syntax-check)
      (format "Syntax error macroexpanding %sat (%s).\n%s\n"
              (if symbol (str symbol " ") "")
              loc
              (or cause ""))

      (= phase :macroexpansion)
      (format "Unexpected error%s macroexpanding %sat (%s).\n%s\n"
              cause-type
              (if symbol (str symbol " ") "")
              loc
              cause)

      (= phase :compile-syntax-check)
      (format "Syntax error%s compiling %sat (%s).\n%s\n"
              cause-type
              (if symbol (str symbol " ") "")
              loc
              cause)

      (= phase :compilation)
      (format "Unexpected error%s compiling %sat (%s).\n%s\n"
              cause-type
              (if symbol (str symbol " ") "")
              loc
              cause)

      (= phase :read-eval-result)
      (format "Error reading eval result%s at %s (%s).\n%s\n" cause-type symbol loc cause)

      (= phase :print-eval-result)
      (format "Error printing return value%s at %s (%s).\n%s\n" cause-type symbol loc cause)

      (= phase :execution)
      (format "Execution error%s at %s(%s).\n%s\n"
              cause-type
              (if symbol (str symbol " ") "")
              loc
              cause)

      :else
      (format "Error%s (%s).\n%s\n" cause-type loc cause))))

(defn err->msg
  "Helper to return an error message string from an exception."
  [e]
  ;; CLJW: Throwable->map not available, use simplified path
  (let [msg (ex-message e)]
    (if msg
      (str "Execution error at REPL.\n" msg "\n")
      (str "Execution error at REPL.\n" (str e) "\n"))))

(defn repl-caught
  "Default :caught hook for repl"
  [e]
  (binding [*out* *err*]
    (print (err->msg e))
    (flush)))

;; CLJW: simplified repl-requires — CW-available namespaces only
(def ^{:doc "A sequence of lib specs that are applied to `require`
by default when a new command-line REPL is started."} repl-requires
  '[[clojure.repl :refer (doc find-doc)]
    [clojure.pprint :refer (pp pprint)]])

(defmacro with-read-known
  "Evaluates body with *read-eval* set to a \"known\" value,
   i.e. substituting true for :unknown if necessary."
  [& body]
  `(binding [*read-eval* (if (= :unknown *read-eval*) true *read-eval*)]
     ~@body))

;; CLJW: simplified repl — no LineNumberingPushbackReader or DynamicClassLoader
(defn repl
  "Generic, reusable, read-eval-print loop. By default, reads from *in*,
  writes to *out*, and prints exception summaries to *err*. Options
  are sequential keyword-value pairs."
  [& options]
  (let [{:keys [init need-prompt prompt flush read eval print caught]
         :or {init        #()
              need-prompt #(identity true)
              prompt      repl-prompt
              flush       flush
              read        repl-read
              eval        eval
              print       prn
              caught      repl-caught}}
        (apply hash-map options)
        request-prompt (Object.)
        request-exit (Object.)
        read-eval-print
        (fn []
          (try
            (let [input (with-read-known (read request-prompt request-exit))]
              (or (#{request-prompt request-exit} input)
                  ;; CLJW: *1/*2/*3/*e not dynamic, skip set!
                  (let [value (eval input)]
                    (try
                      (print value)
                      (catch Exception e
                        (throw (ex-info nil {:clojure.error/phase :print-eval-result} e)))))))
            (catch Exception e
              (caught e))))]
    (with-bindings
      (binding [*repl* true]
        (try
          (init)
          (catch Exception e
            (caught e)))
        (prompt)
        (flush)
        (loop []
          (when-not
           (try (identical? (read-eval-print) request-exit)
                (catch Exception e
                  (caught e)
                  nil))
            (when (need-prompt)
              (prompt)
              (flush))
            (recur)))))))

;; CLJW: simplified load-script — uses load-file
(defn load-script
  "Loads Clojure source from a file given its path."
  [path]
  (load-file path))

;; CLJW: no main function (CW has its own Zig entry point)
;; CLJW: no report-error, init-opt, eval-opt, main-dispatch, legacy-* (JVM CLI internals)
