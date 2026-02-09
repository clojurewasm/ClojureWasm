;; clojure.stacktrace — print Clojure-centric stack traces.
;; UPSTREAM-DIFF: Simplified for CW error model (no Java Throwable/StackTraceElement).
;; Uses Throwable->map to extract error info and call stack.

(ns clojure.stacktrace)

(defn root-cause
  "Returns the last 'cause' Throwable in a chain of Throwables."
  {:added "1.1"}
  [tr]
  ;; CLJW: CW has no cause chains — ex-cause always returns nil
  (if-let [cause (ex-cause tr)]
    (recur cause)
    tr))

(defn print-trace-element
  "Prints a Clojure-oriented view of one element in a stack trace."
  {:added "1.1"}
  [e]
  ;; CLJW: e is a [ns/fn file line] vector from Throwable->map :trace
  (let [sym (str (nth e 0))
        file (str (nth e 1))
        line (nth e 2)]
    (printf "%s (%s:%s)" sym file line)))

(defn print-throwable
  "Prints the class and message of a Throwable. Prints the ex-data map
  if present."
  {:added "1.1"}
  [tr]
  (let [m (Throwable->map tr)]
    (printf "%s" (or (:cause m) (str tr)))
    (when-let [info (ex-data tr)]
      (println)
      (pr info))))

(defn print-stack-trace
  "Prints a Clojure-oriented stack trace of tr, a Throwable.
  Prints a maximum of n stack frames (default: unlimited).
  Does not print chained exceptions (causes)."
  {:added "1.1"}
  ([tr] (print-stack-trace tr nil))
  ([tr n]
   (let [m (Throwable->map tr)
         st (:trace m)]
     (print-throwable tr)
     (println)
     (print " at ")
     (if-let [e (first st)]
       (print-trace-element e)
       (print "[empty stack trace]"))
     (println)
     (doseq [e (if (nil? n)
                 (rest st)
                 (take (dec n) (rest st)))]
       (print "    ")
       (print-trace-element e)
       (println)))))

(defn print-cause-trace
  "Like print-stack-trace but prints chained exceptions (causes)."
  {:added "1.1"}
  ([tr] (print-cause-trace tr nil))
  ([tr n]
   (print-stack-trace tr n)
   (when-let [cause (ex-cause tr)]
     (print "Caused by: ")
     (recur cause n))))

(defn e
  "REPL utility. Prints a brief stack trace for the root cause of the
  most recent exception."
  {:added "1.1"}
  []
  (print-stack-trace (root-cause *e) 8))
