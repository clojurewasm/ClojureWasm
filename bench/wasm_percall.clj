(ns wasm-percall
  "The per-crossing cost of one `wasm/call`, in nanoseconds
  ([CLJW-WASM-BENCH-BLIND], ADR-0196 D4).

  Every workload in bench/wasm_bench.sh loops INSIDE the module and crosses
  the cljw -> wasm boundary once per process, so a per-call cost of any size is
  invisible to it. This is the other axis: the loop is on the cljw side and
  only the calls are timed. One module, instantiated once per engine, warmed,
  then `trials` trials of `n` calls per cell; per cell the median, min, max and
  sample standard deviation over trials, in ns, never ms.

  Cells: auto | jit | interp on the runtime thread (`-main`) and on a worker
  (`-worker`, via `future`), plus `fn-call`: a plain Clojure function call in
  the same process. That last row is the platform constant, kept in its own
  datum key so a regression in cljw's call path is distinguishable from one in
  the engine. `big-auto | big-jit | big-interp` call a trivial export of a
  47 KB module: a per-call cost that grows with module size shows up as the
  gap between `big-jit` and `jit-main` ([CLJW-WASM-JIT-PERCALL-SCALES],
  zwasm/D-585). Copies the discipline of zwasm's own bench/latency runner.

  Run (needs a -Dwasm ReleaseSafe binary):
    ./zig-out/bin/cljw -cp bench -m wasm-percall [--n=20000] [--trials=7] [--yaml=FILE]

  ON-DEMAND ONLY (Layer 4 bench, never a gate step; a measurement is not an
  assertion). `--yaml` writes the datum bench_domain.py's from_wasm_percall reads."
  (:require [clojure.string :as str]))

(def add-wasm "bench/wasm/ffi/add.wasm")
(def three-f64-wasm "test/e2e/fixtures/wasm/three_f64.wasm")
(def echo-component "test/e2e/fixtures/wasm/echo.component.wasm")

;; 47 KB, built from bench/wasm/percall/zigcool.zig with
;;   zig build-exe -target wasm32-freestanding -fno-entry -rdynamic -O ReleaseSmall zigcool.zig
(def big-wasm "bench/wasm/percall/zigcool.wasm")

(defn parse-args [args]
  (reduce (fn [opts arg]
            (cond
              (str/starts-with? arg "--n=") (assoc opts :n (Long/parseLong (subs arg 4)))
              (str/starts-with? arg "--trials=") (assoc opts :trials (Long/parseLong (subs arg 9)))
              (str/starts-with? arg "--yaml=") (assoc opts :yaml (subs arg 7))
              :else (throw (ex-info (str "unknown option: " arg) {:arg arg}))))
          {:n 20000 :trials 7 :yaml nil}
          args))

(defn plain-add [a b] (+ a b))

(defn burn-wasm [m n]
  (loop [i 0] (when (< i n) (wasm/call m "add" i 1) (recur (inc i)))))

(defn burn-big [m n]
  (loop [i 0] (when (< i n) (wasm/call m "popcount" i) (recur (inc i)))))

(defn burn-fn [n]
  (loop [i 0] (when (< i n) (plain-add i 1) (recur (inc i)))))

(defn ns-per
  "Nanoseconds per call for one trial of `n` calls: time `f`, divide."
  [f n]
  (let [t0 (System/nanoTime)]
    (f)
    (long (/ (double (- (System/nanoTime) t0)) n))))

(defn cells
  "Ordered [name thunk] pairs. Each thunk runs one trial of n calls.

  Every cell owns its instance. An `:interp` instance traps once it is called
  from a thread other than the one that first ran it (staging 2026-10-21,
  zwasm d74e63b4; card CLJW-WASM-INTERP-THREAD-HOP). `future` may land each
  trial on a different pool thread, so `interp-worker` instantiates on the
  worker inside its trial; that one load, amortised over n calls, is part of
  its number.

  `core-f64x3` / `component-f64` pin [CLJW-WASM-CALL-22X]: core wasm/call
  against component-call on an f64 shape. They measured 22x apart on v1.10.18
  (14.2 us vs 0.65 us), before ADR-0195 moved the program off the initial
  thread and before the per-handle exportSig cache. The cells stay so the two
  surfaces cannot drift apart unseen."
  [n]
  (let [ld (fn [opts] (wasm/load add-wasm (assoc opts :fuel 0)))
        big (fn [opts] (wasm/load big-wasm (assoc opts :fuel 0)))
        three  (wasm/load three-f64-wasm)
        comp   (wasm/load-component echo-component)
        on-worker (fn [f] #(deref (future (f))))
        auto-m (ld {}) auto-w (ld {})
        jit-m (ld {:engine :jit}) jit-w (ld {:engine :jit})
        int-m (ld {:engine :interp})
        big-auto (big {}) big-jit (big {:engine :jit}) big-interp (big {:engine :interp})]
    [["auto-main"     #(burn-wasm auto-m n)]
     ["auto-worker"   (on-worker #(burn-wasm auto-w n))]
     ["jit-main"      #(burn-wasm jit-m n)]
     ["jit-worker"    (on-worker #(burn-wasm jit-w n))]
     ["interp-main"   #(burn-wasm int-m n)]
     ["interp-worker" (on-worker #(burn-wasm (ld {:engine :interp}) n))]
     ["core-f64x3"    #(loop [i 0] (when (< i n) (wasm/call three "sum3" 1.5 2.5 3.5) (recur (inc i))))]
     ["component-f64" #(loop [i 0] (when (< i n) (wasm/component-call comp "echo-f64" 1.5) (recur (inc i))))]
     ["big-auto"      #(burn-big big-auto n)]
     ["big-jit"       #(burn-big big-jit n)]
     ["big-interp"    #(burn-big big-interp n)]
     ["fn-call"       #(burn-fn n)]]))

(defn stats
  "Median, min, max and sample standard deviation of a non-empty seq, as longs."
  [xs]
  (let [s (vec (sort xs))
        k (count s)
        median (if (odd? k)
                 (nth s (quot k 2))
                 (/ (+ (nth s (dec (quot k 2))) (nth s (quot k 2))) 2.0))
        mean (/ (double (reduce + s)) k)
        var (if (> k 1)
              (/ (reduce + (map #(let [d (- % mean)] (* d d)) s)) (dec k))
              0.0)]
    {:median (long median) :min (first s) :max (peek s) :sd (long (Math/sqrt var))}))

(defn measure
  "Warm every path once, then `trials` trials per cell. Returns ordered
  [name stats] pairs."
  [n trials]
  (let [cs (cells n)]
    (doseq [[_ thunk] cs] (thunk))
    (let [samples (reduce (fn [acc _]
                            (reduce (fn [acc [name thunk]]
                                      (update acc name (fnil conj []) (ns-per thunk n)))
                                    acc cs))
                          {} (range trials))]
      (mapv (fn [[name _]] [name (stats (samples name))]) cs))))

(defn print-table [rows n trials load-avg]
  (println (format "%-14s %8s %8s %8s %8s" "cell" "median" "min" "max" "sd"))
  (doseq [[name {:keys [median min max sd]}] rows]
    (println (format "%-14s %8d %8d %8d %8d" name median min max sd)))
  (println (str "(ns per call; " trials " trials x " n " calls per cell"
                (when load-avg (str "; load average " load-avg)) ")")))

(defn first-line [path]
  ;; procfs files stat as size 0 and read back empty on cljw today, so these
  ;; are best-effort: nil when unavailable, and the datum omits the field.
  (let [s (try (slurp path) (catch Throwable _ ""))]
    (when-not (str/blank? s) (first (str/split-lines s)))))

(defn cpu-model []
  (some->> (try (slurp "/proc/cpuinfo") (catch Throwable _ ""))
           str/split-lines
           (filter #(str/starts-with? % "model name"))
           first
           (re-find #":\s*(.*)$")
           second))

(defn load-average []
  (some-> (first-line "/proc/loadavg") (str/split #" ") first))

(defn cljw-version []
  (str "ClojureWasm v"
       (or (second (re-find #"\.version = \"([^\"]+)\"" (slurp "build.zig.zon"))) "?")
       " (wasm)"))

(defn yaml-line [[name {:keys [median min max sd]}]]
  (format "  %s: {median: %d, min: %d, max: %d, sd: %d}" name median min max sd))

(defn yaml
  "The datum bench_domain.py's from_wasm_percall reads: env, percall_ns, and
  the platform constant in its own key."
  [rows {:keys [n trials]} cpu load-avg]
  (let [platform? #(= "fn-call" (first %))]
    (str/join "\n"
              (concat
               ["# Wasm per-crossing cost: one wasm/call, cljw-side loop, ns per call"
                (str "# Generated: " (java.time.LocalDateTime/now) " by bench/wasm_percall.clj")
                ""
                (str "date: \"" (java.time.LocalDate/now) "\"")
                ""
                "env:"
                (str "  machine: " (System/getProperty "os.name") " " (System/getProperty "os.arch"))]
               (when cpu [(str "  cpu: " cpu)])
               [(str "  cljw: " (cljw-version))
                "  tool: bench/wasm_percall.clj"
                (str "  calls_per_trial: " n)
                (str "  trials: " trials)]
               (when load-avg [(str "  load_average: " load-avg)])
               ["" "percall_ns:"]
               (map yaml-line (remove platform? rows))
               ["" "platform_constant_ns:"]
               (map yaml-line (filter platform? rows))
               [""]))))

(defn -main [& args]
  (let [{:keys [n trials] :as opts} (parse-args args)
        rows (measure n trials)
        cpu (cpu-model)
        load-avg (load-average)]
    (print-table rows n trials load-avg)
    (when-let [path (:yaml opts)]
      (spit path (yaml rows opts cpu load-avg))
      (println "YAML written:" path))))
