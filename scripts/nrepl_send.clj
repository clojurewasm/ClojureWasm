#!/usr/bin/env bb
(ns nrepl-send
  "Dependency-free Clojure nREPL probe using the shared .cljc transport."
  (:require [dev.nrepl :as nrepl]))

(defn usage! []
  (binding [*out* *err*]
    (println "usage: bb scripts/nrepl_send.clj PORT [CODE|-] [--host H] [--op OP] [--prefix P] [--ns NS] [--sym S]"))
  (System/exit 2))

(defn parse-args [args]
  (when (empty? args) (usage!))
  (loop [xs (rest args)
         opts {:port (Long/parseLong (first args))
               :host "127.0.0.1"
               :op "eval"}]
    (if (empty? xs)
      opts
      (let [[x value & more] xs]
        (case x
          "--host" (recur more (assoc opts :host value))
          "--op" (recur more (assoc opts :op value))
          "--prefix" (recur more (assoc opts :prefix value))
          "--ns" (recur more (assoc opts :ns value))
          "--sym" (recur more (assoc opts :sym value))
          (if (:code opts)
            (usage!)
            (recur (rest xs) (assoc opts :code x))))))))

(defn message [{:keys [op code prefix ns sym]}]
  (cond-> {"op" op}
    (= op "eval") (assoc "code" (if (= code "-") (slurp *in*) (or code "")))
    prefix (assoc "prefix" prefix)
    ns (assoc "ns" ns)
    sym (assoc "sym" sym)))

(defn -main [& args]
  (let [{:keys [host port] :as opts} (parse-args args)
        conn (nrepl/connect host port)
        status
        (try
          (nrepl/clone-session! conn)
          (let [responses (nrepl/request conn (message opts))]
            (doseq [response responses] (prn response))
            (if (nrepl/response-error? responses) 1 0))
          (finally
            (nrepl/close conn)))]
    (System/exit status)))

(apply -main *command-line-args*)
