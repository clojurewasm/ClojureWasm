(ns harness.process
  "Babashka-only process boundary for native ClojureWasm harnesses.

  Domain code talks nREPL through dev.nrepl. This namespace alone owns child
  processes, temporary directories, port allocation, and cleanup."
  (:require [babashka.fs :as fs]
            [babashka.process :as p]
            [clojure.string :as str]))

(def repo-root
  (str (fs/canonicalize (fs/path (or (System/getenv "CLJW_REPO") ".")))))

(def cljw-bin (str (fs/path repo-root "zig-out/bin/cljw")))

(defn env-set? [name]
  (let [v (System/getenv name)]
    (and v (not (empty? v)))))

(defn ensure-cljw-built! []
  (when-not (env-set? "CLJW_SKIP_BUILD")
    (let [opt (or (System/getenv "CLJW_OPT") "ReleaseSafe")
          result (p/shell {:dir repo-root :out :inherit :err :inherit :continue true}
                          "zig" "build" "-Dwasm" (str "-Doptimize=" opt))]
      (when-not (zero? (:exit result))
        (throw (ex-info "cljw build failed" {:exit (:exit result)}))))))

(defn cljw-eval-line [code]
  (let [result (p/shell {:dir repo-root
                         :out :string
                         :err :out
                         :continue true}
                        cljw-bin "-e" code)
        lines (str/split-lines (:out result))]
    (or (first lines) "<cljw-missing>")))

(defn temp-dir [prefix]
  (str (fs/create-temp-dir {:prefix prefix})))

(defn- read-port [path]
  (when (fs/exists? path)
    (let [s (.trim (slurp (str path)))]
      (when-not (empty? s) (Long/parseLong s)))))

(defn start-server!
  "Start command in dir and wait for its .nrepl-port. Returns an owned server."
  [{:keys [command dir startup-seconds log-file extra-env]
    :or {startup-seconds 20}}]
  (fs/create-dirs dir)
  (let [port-file (fs/path dir ".nrepl-port")
        log-file (or log-file (fs/path dir "server.log"))
        process (p/process command {:dir dir
                                    :out (fs/file log-file)
                                    :err :out
                                    :extra-env extra-env})
        deadline (+ (System/currentTimeMillis) (* 1000 startup-seconds))]
    (loop []
      (if-let [port (read-port port-file)]
        {:process process :port port :dir dir :log-file (str log-file)}
        (if (< (System/currentTimeMillis) deadline)
          (do (Thread/sleep 100) (recur))
          (do
            (p/destroy-tree process)
            (let [log (when (fs/exists? log-file) (slurp (str log-file)))]
              (fs/delete-tree dir)
              (throw (ex-info "nREPL server did not publish a port"
                              {:command command :log log})))))))))

(defn stop-server! [{:keys [process]}]
  (when process
    (p/destroy-tree process)))

(defn cleanup-dir! [dir]
  (when (and dir (fs/exists? dir))
    (fs/delete-tree dir)))

(defn start-cljw!
  "Start a cljw nREPL on an OS-assigned port (`--port 0`). The server writes
  the BOUND port to .nrepl-port, which start-server! reads, so no port is
  chosen before bind. Returns an owned server."
  ([] (start-cljw! {}))
  ([{:keys [classpath]}]
   (let [dir (temp-dir "cljw-nrepl-")
         command (cond-> [cljw-bin "nrepl" "--port" "0"]
                   classpath (conj "-cp" classpath))]
     (start-server! {:command command
                     :dir dir
                     :startup-seconds 20
                     :extra-env {"CLJW_EVAL_DEADLINE_MS" "20000"}}))))

(def mainline-deps
  "{:deps {nrepl/nrepl {:mvn/version \"1.3.1\"}}}")

(def mainline-cider-deps
  "{:deps {nrepl/nrepl {:mvn/version \"1.3.1\"}
           cider/cider-nrepl {:mvn/version \"0.62.1\"}}}")

(defn start-mainline!
  ([] (start-mainline! false))
  ([with-cider?]
   (let [dir (temp-dir "clj-nrepl-")
         middleware (when with-cider?
                      ["--middleware" "[\"cider.nrepl/cider-middleware\"]"])
         deps (if with-cider? mainline-cider-deps mainline-deps)
         command (into ["clj" "-J-Xmx2g" "-Sdeps" deps
                        "-M" "-m" "nrepl.cmdline" "--port" "0"]
                       middleware)]
     (start-server! {:command command :dir dir :startup-seconds 120}))))

(defn with-server [server f]
  (try
    (f server)
    (finally
      (stop-server! server)
      (cleanup-dir! (:dir server)))))
