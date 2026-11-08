;; scripts/dev/nrepl.cljc — a minimal nREPL client that runs on BOTH cljw and
;; babashka, sharing one implementation.
;;
;; The ONLY runtime difference is how a TCP socket is opened and read/written:
;; cljw exposes `cljw.net/connect` with `.read`/`.write` directly on the socket,
;; while the JVM/babashka side goes through get{Input,Output}Stream. Those three
;; functions are the entire reader-conditional surface; everything above them —
;; the request encoding, the incremental decode, the response loop — is shared.
(ns dev.nrepl
  (:require [dev.bencode :as b]))

;; --- the runtime seam -----------------------------------------------------
(defn connect [host port]
  #?(:cljw {:sock (cljw.net/connect host port)
            :request-id (atom 0)
            :session (atom nil)}
     :default (let [s (java.net.Socket. ^String host ^long port)]
                (.setSoTimeout s 20000)
                {:sock s
                 :in (.getInputStream s)
                 :out (.getOutputStream s)
                 :request-id (atom 0)
                 :session (atom nil)})))

(defn- write-bytes [conn ba]
  #?(:cljw (.write (:sock conn) ba (alength ba))
     :default (doto (:out conn) (.write ba) (.flush))))

(defn- read-bytes
  "Fill `buf`; => number of bytes read, or -1/nil at EOF."
  [conn buf]
  #?(:cljw (.read (:sock conn) buf)
     :default (.read (:in conn) buf)))

(defn close [conn] (.close (:sock conn)))

;; --- the shared protocol loop ---------------------------------------------
(defn- unsigned [x] (bit-and x 255))

(defn request
  "Send one string-keyed nREPL request and collect its responses.
   => vector of response maps (string keys, as they arrive on the wire).
   A cloned session is attached automatically unless the request names one."
  [conn msg]
  (let [id (str (swap! (:request-id conn) inc))
        session @(:session conn)
        msg (cond-> (assoc msg "id" id)
              (and session (not (contains? msg "session")))
              (assoc "session" session))
        req (.getBytes (b/encode-dict msg) "UTF-8")]
    (write-bytes conn req)
    (loop [buf [] consumed 0 acc []]
      ;; cider-nrepl can put a terminal status before a large completion
      ;; payload in the same socket burst. Match the old proven client window
      ;; so the whole burst is decoded before the done check.
      (let [chunk (byte-array 65536)
            n (read-bytes conn chunk)]
        (if (or (nil? n) (<= n 0))
          acc
          (let [buf' (into buf (map unsigned (take n (seq chunk))))
                r (try
                    (b/decode-all buf' consumed)
                    (catch Exception e
                      (throw
                       (ex-info "invalid nREPL bencode response"
                                {:offset consumed
                                 :buffer-size (count buf')
                                 :next-bytes (vec (take 48 (drop consumed buf')))}
                                e))))
                msgs (first r)
                acc' (into acc msgs)
                done? (some (fn [m]
                              (let [st (get m "status")]
                                (and (coll? st) (some (fn [s] (= s "done")) st))))
                            msgs)]
            (if done?
              acc'
              (recur buf' (second r) acc'))))))))

(defn clone-session!
  "Clone and retain one nREPL session on `conn`; return its id."
  [conn]
  (let [msgs (request conn {"op" "clone"})
        session (some (fn [m] (get m "new-session")) msgs)]
    (when-not session
      (throw (ex-info "nREPL clone returned no session" {:responses msgs})))
    (reset! (:session conn) session)
    session))

(defn close-session!
  "Close the retained session, if any. The TCP connection stays open."
  [conn]
  (when-let [session @(:session conn)]
    (request conn {"op" "close" "session" session})
    (reset! (:session conn) nil)))

(defn eval-code
  "Evaluate `code` through the connected nREPL and fully drain responses."
  [conn code]
  (request conn {"op" "eval" "code" code}))

(defn response-output
  "Concatenate stdout/stderr response fragments in wire order."
  [msgs]
  (apply str
         (mapcat (fn [m] (remove nil? [(get m "out") (get m "err")]))
                 msgs)))

(defn response-error?
  "True when the server reported an exception or eval-error status."
  [msgs]
  (boolean
   (some (fn [m]
           (or (some? (get m "ex"))
               (some (fn [s] (= s "eval-error")) (get m "status"))))
         msgs)))

(defn print-responses
  "Render responses the way a REPL client should. => true if the server
   reported an evaluation error (so a caller can set its exit code)."
  [msgs]
  (reduce (fn [failed m]
            (when-let [o (get m "out")] (print o) (flush))
            (when-let [e (get m "err")] (print e) (flush))
            (when-let [v (get m "value")] (println "value" v))
            (when-let [x (get m "ex")] (println "ex" x))
            (or failed (response-error? [m])))
          false
          msgs))
