(ns harness.nrepl-eval
  "Pure differential/corpus evaluation over the shared nREPL transport."
  (:require [clojure.string :as str]
            [dev.nrepl :as nrepl]))

(def qualified-ns-pattern
  #"[A-Za-z][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+/")

(defn qualified-namespaces [expr]
  (->> (re-seq qualified-ns-pattern expr)
       (map #(subs % 0 (dec (count %))))
       distinct
       sort))

(defn require-prefix [expr]
  (apply str
         (map (fn [ns]
                (str "(try (require '" ns ") (catch Throwable _ nil))"))
              (qualified-namespaces expr))))

(defn printable-code [expr]
  (str "(do " (require-prefix expr) " (prn " expr "))"))

(defn oracle-code
  "`expr` printed with `prn`, or `<clj-error> SimpleName` when it throws. The
  class is reduced to its simple name on both runtimes: clj reports
  `java.lang.IllegalArgumentException` where cljw reports
  `IllegalArgumentException` (AD-003), and the kind is what a golden locks."
  [expr]
  (str "(do " (require-prefix expr)
       " (try (prn " expr ")"
       " (catch Throwable e"
       " (println (str \"<clj-error> \" (re-find #\"[^.]+$\" (.getName (class e))))))))"))

(defn first-output-line [msgs]
  (let [output (nrepl/response-output msgs)
        lines (str/split-lines output)]
    (cond
      (seq lines) (first lines)
      (nrepl/response-error? msgs)
      (str "<nrepl-error> "
           (or (some #(get % "ex") msgs)
               (some #(get % "err") msgs)
               "unknown"))
      :else "<nrepl-missing>")))

(defn eval-line [conn expr]
  (first-output-line (nrepl/eval-code conn (printable-code expr))))

(defn oracle-line [conn expr]
  (first-output-line (nrepl/eval-code conn (oracle-code expr))))

(defn open-session [host port]
  (let [conn (nrepl/connect host port)]
    (nrepl/clone-session! conn)
    conn))

(defn close-session [conn]
  (try
    (nrepl/close-session! conn)
    (finally (nrepl/close conn))))
