#!/usr/bin/env bb
(ns completion-oracle
  "Capture and compare CIDER completion responses with shared Clojure nREPL IO."
  (:require [babashka.fs :as fs]
            [cheshire.core :as json]
            [clojure.set :as set]
            [dev.nrepl :as nrepl]
            [harness.process :as process]))

(def fixture-dir "test/e2e/fixtures/completion")
(def requests-path (str fixture-dir "/requests.json"))
(def expected-path (str fixture-dir "/expected.json"))

(defn usage! []
  (binding [*out* *err*]
    (println "usage: bb scripts/completion_oracle.clj --capture|--diff|--cljw|--regression"))
  (System/exit 2))

(defn mode [args]
  (let [modes (filter #{"--capture" "--diff" "--cljw" "--regression"} args)]
    (if (= 1 (count modes)) (first modes) (usage!))))

(defn normalize [candidates]
  (->> (or candidates [])
       (map (fn [candidate]
              (cond-> {"candidate" (get candidate "candidate")
                       "type" (get candidate "type")}
                (contains? candidate "ns")
                (assoc "ns" (get candidate "ns")))))
       (sort-by #(or (get % "candidate") ""))
       vec))

(defn run-probes
  ([port groups]
   (run-probes port groups normalize))
  ([port groups project]
   (reduce
    (fn [result group]
      (let [conn (nrepl/connect "127.0.0.1" port)]
        (try
          (nrepl/clone-session! conn)
          (doseq [code (get group "setup" [])]
            (nrepl/eval-code conn code))
          (reduce
           (fn [result probe]
             (let [key (str (get group "group") "|" (get probe "prefix"))
                   responses
                   (try
                     (nrepl/request
                      conn
                      {"op" "completions"
                       "prefix" (get probe "prefix")
                       "ns" (get probe "ns" "user")})
                     (catch Exception e
                       (throw (ex-info "completion request failed"
                                       {:probe key :port port}
                                       e))))
                   candidates (some #(get % "completions") responses)]
               (assoc result key (project candidates))))
           result
           (get group "probes"))
          (finally
            (nrepl/close conn)))))
    (sorted-map)
    groups)))

(defn print-json [value]
  (println (json/generate-string value {:pretty true})))

(defn diff-results [mainline cljw]
  (let [diffs
        (reduce
         (fn [diffs key]
           (let [main (get mainline key)
                 actual (get cljw key)]
             (if (= main actual)
               (do
                 (println (str "OK   " key " (" (count main) ")"))
                 diffs)
               (let [main-set (set main)
                     actual-set (set (or actual []))]
                 (println (str "DIFF " key ": mainline " (count main)
                               " vs cljw " (count (or actual []))))
                 (doseq [candidate (take 15 (sort-by pr-str (set/difference main-set actual-set)))]
                   (println (str "  -mainline-only " (json/generate-string candidate))))
                 (doseq [candidate (take 15 (sort-by pr-str (set/difference actual-set main-set)))]
                   (println (str "  +cljw-only     " (json/generate-string candidate))))
                 (inc diffs)))))
         0
         (sort (keys mainline)))]
    (println "---")
    (println (str (- (count mainline) diffs) "/" (count mainline)
                  " probes match"))
    (if (zero? diffs) 0 1)))

(defn capture! [groups]
  (process/with-server
   (process/start-mainline! true)
   (fn [server]
     (let [responses (run-probes (:port server) groups)]
       (fs/create-dirs fixture-dir)
       (spit expected-path
             (str (json/generate-string responses {:pretty true}) "\n"))
       (println (str "captured " (count responses)
                     " probe responses -> " expected-path))
       0))))

(defn cljw! [groups]
  (process/ensure-cljw-built!)
  (process/with-server
   (process/start-cljw!)
   (fn [server]
     (print-json (run-probes (:port server) groups))
     0)))

(defn compare! [groups]
  (process/ensure-cljw-built!)
  (process/with-server
   (process/start-mainline! true)
   (fn [mainline-server]
     (let [mainline (run-probes (:port mainline-server) groups)]
       (process/with-server
        (process/start-cljw!)
        (fn [cljw-server]
          (diff-results mainline
                        (run-probes (:port cljw-server) groups))))))))

(defn regression! [groups]
  (let [expected (json/parse-string (slurp expected-path))
        must {"classes|Character" ["Character" "java.lang.Character"]
              "classes|Big" ["BigDecimal" "BigInteger"
                             "java.math.BigDecimal" "java.math.BigInteger"]
              "core_vars|def" ["def" "definterface" "defmethod" "defmulti"
                               "defn" "defn-" "defonce" "defprotocol"
                               "defrecord" "deftype"]
              "keywords|:req" [":req" ":req-un" ":require"]
              "static_members|Character/" ["Character/BYTES"
                                            "Character/MIN_RADIX"
                                            "Character/isDigit"
                                            "Character/toUpperCase"
                                            "Character/isEmoji"
                                            "Character/isJavaLetter"
                                            "Character/DIRECTIONALITY_UNDEFINED"]}
        must-not {"classes|Character" ["java.lang.CharacterData00"
                                       "java.lang.CharacterData"]
                  "static_members|Character/" ["Character/TYPE"]}
        subset-groups (set/union (set (keys must)) (set (keys must-not)))
        check (fn [key raw]
                (let [raw (vec (or raw []))
                      raw-names (mapv #(get % "candidate") raw)
                      got (normalize raw)
                      names (set (map #(get % "candidate") got))
                      exp (get expected key [])
                      exp-by-name (into {} (map (juxt #(get % "candidate") identity) exp))
                      extras (vec (remove #(contains? exp-by-name
                                                       (get % "candidate"))
                                          got))
                      missing (vec (remove names (get must key [])))
                      bad-meta (vec (remove #(= % (get exp-by-name
                                                   (get % "candidate")))
                                            got))
                      leaked (vec (filter names (get must-not key [])))]
                  (cond
                    (not= raw-names (vec (sort raw-names)))
                    {:kind :not-sorted :actual (take 8 raw-names)}

                    (contains? subset-groups key)
                    (cond
                      (seq extras) {:kind :unexpected-candidates :actual extras}
                      (seq missing) {:kind :missing-required :actual missing}
                      (seq bad-meta) {:kind :metadata-mismatch :actual bad-meta}
                      (seq leaked) {:kind :forbidden-candidates :actual leaked}
                      :else nil)

                    (not= got exp)
                    {:kind :fixture-mismatch
                     :mainline-count (count exp)
                     :cljw-count (count got)
                     :mainline-only (take 6 (set/difference (set exp) (set got)))
                     :cljw-only (take 6 (set/difference (set got) (set exp)))}

                    :else nil)))]
    (process/ensure-cljw-built!)
    (process/with-server
     (process/start-cljw!)
     (fn [server]
       (let [raw-results (run-probes (:port server) groups
                                     #(vec (or % [])))
             failures
             (reduce-kv
              (fn [failures key raw]
                (if-let [failure (check key raw)]
                  (do
                    (println (str "FAIL " key ": "
                                  (json/generate-string failure)))
                    (inc failures))
                  (do
                    (println (str "PASS " key
                                  (if (contains? subset-groups key)
                                    " (subset)"
                                    " (exact)")))
                    failures)))
              0
              raw-results)]
         (if (zero? failures) 0 1))))))

(defn -main [& args]
  (let [groups (json/parse-string (slurp requests-path))
        status (case (mode args)
                 "--capture" (capture! groups)
                 "--cljw" (cljw! groups)
                 "--diff" (compare! groups)
                 "--regression" (regression! groups))]
    (System/exit status)))

(apply -main *command-line-args*)
