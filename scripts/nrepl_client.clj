;; scripts/nrepl_client.clj — the cljw-side entry point to the dev nREPL client.
;;
;; The client itself lives in scripts/dev/nrepl.cljc + scripts/dev/bencode.cljc
;; and is SHARED with the babashka entry point (scripts/dev_repl.clj), so there
;; is exactly one implementation of the protocol rather than one per runtime.
;; Running it here is what dogfoods cljw: every use exercises cljw.net sockets,
;; byte arrays and UTF-8 length handling, so a regression in any of them breaks
;; a tool the loop uses daily instead of waiting for someone to write a test.
;;
;; Usage:
;;   echo '(+ 1 2)' | CLJW_REPL_PORT=7899 cljw -cp scripts scripts/nrepl_client.clj
;;
;; Prints `value <v>` / `out` / `err` / `ex <e>` per response; exits 1 if the
;; server reported an evaluation error.
(require '[dev.nrepl :as nrepl])

(def port (Integer/parseInt (or (System/getenv "CLJW_REPL_PORT") "7899")))
(def host (or (System/getenv "CLJW_REPL_HOST") "127.0.0.1"))

;; `(slurp *in*)` is not available under cljw (its slurp takes a path string),
;; so stdin is read line by line.
(defn- read-stdin []
  (loop [acc []]
    (if-let [l (read-line)]
      (recur (conj acc l))
      (apply str (interpose "\n" acc)))))

(let [code (read-stdin)]
  (when (empty? (.trim code))
    (println "nrepl_client: nothing on stdin")
    (System/exit 2))
  (let [conn (nrepl/connect host port)
        failed (nrepl/print-responses (nrepl/eval-code conn code))]
    (nrepl/close conn)
    (System/exit (if failed 1 0))))
