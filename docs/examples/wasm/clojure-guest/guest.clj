;; cljw hosting cljw: untrusted Clojure inside a Wasm sandbox.
;;
;; The guest is cljw itself, built for wasm32-wasi (it is not committed):
;;   zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
;; Run from the repository root with a wasm-enabled cljw (`cljw --version`
;; shows `wasm`):
;;   cljw docs/examples/wasm/clojure-guest/guest.clj
;;
;; The guest reads deps.edn from its working directory at startup, so it needs
;; one preopened directory. An empty scratch directory is the whole grant: no
;; other path, no environment, no network.

(def guest (or (System/getenv "CLJW_GUEST") "zig-out/bin/cljw.wasm"))
(def scratch "/tmp/cljw-guest-scratch")
(.mkdirs (java.io.File. scratch))

(defn eval-in-guest
  "Evaluate the Clojure source `src` in a fresh guest instance. Returns
   {:out :err :exit}; a guest error or trap is data, never a host exception."
  ([src] (eval-in-guest src {}))
  ([src opts]
   (wasm/run guest (merge {:args ["cljw" "-"] :stdin src :dir scratch} opts))))

(defn show [label src opts]
  (let [t0 (System/nanoTime)
        r (eval-in-guest src opts)
        ms (Math/round (/ (- (System/nanoTime) t0) 1e6))]
    (println (str label ": " (pr-str r) " " ms " ms"))))

(println "-- programs")
(show "reduce" "(println (reduce + (range 100)))" {})
(show "recursion" "(defn fib [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (println (fib 20))" {})
(show "pipeline" "(println (->> (range 1 20) (map #(* % %)) (filter odd?) (reduce +)))" {})
(show "strings" "(println (clojure.string/upper-case (clojure.string/join \"-\" (reverse (clojure.string/split \"a b c\" #\" \")))))" {})
(show "exception" "(println (try (throw (ex-info \"boom\" {:k 1})) (catch Exception e [(ex-message e) (ex-data e)])))" {})

(println "-- confinement")
(show "fuel" "(loop [] (recur))" {:fuel 100000000})
(show "memory" "(loop [acc ()] (recur (cons 1 acc)))" {:max-memory-pages 1024 :fuel 0})
(show "file" "(println (try (slurp \"/etc/passwd\") (catch Exception e (ex-message e))))" {})
(show "env" "(println (pr-str (System/getenv \"HOME\")))" {})
