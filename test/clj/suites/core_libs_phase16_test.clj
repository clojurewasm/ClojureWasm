;; Bundled namespaces and reader limits: clojure.core.reducers (D-513 (1)),
;; clojure.repl (D-513 finding 2), defprotocol :extend-via-metadata (D-314),
;; tokenizer long-input DoS guard, and the D-556-class BFS queue GC pin.
;;
;; Migrated from test/e2e/phase16_{clojure_core_reducers,clojure_repl,
;; extend_via_metadata,tokenizer_long_input,bfs_queue_gc}.sh; marker names are
;; kept in the assertion messages. Two cases need a fresh process and run in a
;; child cljw: the REPL's refer of doc into user, and the BFS run under
;; CLJW_GC_THRESHOLD_MB=1 (the GC threshold is read once at startup).
(ns suites.core-libs-phase16-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.string :as str]
            [clojure.set]
            [clojure.java.shell :refer [sh]]
            [clojure.core.reducers :as r]
            [clojure.repl :as repl]))

;; ---- clojure.core.reducers ----

(deftest reducers-ns
  (is (= [2 3 4] (into [] (r/map inc [1 2 3]))) "require-and-map")
  (is (= [2 4] (into [] ((r/filter even?) [1 2 3 4]))) "curried-arity")
  ;; fold is SEQUENTIAL (AD-058): pin the VALUE so a later parallelisation
  ;; cannot change it.
  (is (= 49995000 (r/fold + (vec (range 10000)))) "fold-value-on-a-large-vector")
  (is (= 4950 (r/fold 4 + (fn ([] 0) ([a b] (+ a b))) (vec (range 100))))
      "fold-with-a-distinct-combiner")
  (is (= 500 (count (r/foldcat (vec (range 500))))) "foldcat-counts")
  (is (= 2 (let [a (r/cat)] (r/append! a 1) (r/append! a 2) (count a)))
      "append!-returns-the-accumulator")
  (is (= 4 (reduce (fn [a b] (if (> a 3) (reduced a) (+ a b))) 0 (r/mapcat (fn [x] [x x]) [1 2 3 4])))
      "reduced-terminates-through-mapcat"))

;; ---- clojure.repl ----

(deftest clojure-repl-ns
  (let [d (with-out-str (repl/doc interpose))]
    (is (str/includes? d "clojure.core/interpose") "doc_header")
    (is (str/includes? d "([sep] [sep coll])") "doc_arglists")
    (is (str/includes? d "separated by sep") "doc_text"))
  (is (= 'clojure.core/interpose (first (repl/apropos "interpos"))) "apropos")
  (is (pos? (count (repl/dir-fn 'clojure.set))) "dir_fn")
  (is (= "my-fn?" (repl/demunge "my_fn_QMARK_")) "demunge")
  (is (str/includes? (with-out-str (repl/find-doc "separated by sep")) "clojure.core/interpose") "find_doc")
  (is (thrown-with-msg? Exception #"not available" (repl/source-fn 'map)) "source_throws"))

(deftest clojure-repl-refers-at-the-prompt-only
  ;; The interactive REPL refers doc/dir/apropos into user (clojure.main parity);
  ;; a script run deliberately does not. Both are properties of a fresh process.
  (is (str/includes? (:out (sh "zig-out/bin/cljw" "repl" :in "(doc interpose)\n")) "clojure.core/interpose")
      "repl_bare_doc")
  (let [{:keys [out err]} (sh "zig-out/bin/cljw" "-e" "(doc interpose)")]
    (is (str/includes? (str out err) "doc") "script_no_doc")))

;; ---- defprotocol :extend-via-metadata (D-314) ----
;; The method key is the protocol-defining-ns-qualified symbol.

(defprotocol EvmSized :extend-via-metadata true (evm-sized [x]))
(defprotocol EvmVecSized :extend-via-metadata true (evm-vsized [x]))
(extend-protocol EvmVecSized clojure.lang.IPersistentVector (evm-vsized [_] :extend))
(defprotocol EvmMapSized :extend-via-metadata true (evm-msized [x]))
(extend-protocol EvmMapSized clojure.lang.IPersistentMap (evm-msized [_] :extend))
(defprotocol EvmPlain (evm-psize [x]))

(deftest extend-via-metadata
  (let [k (fn [s] (symbol "suites.core-libs-phase16-test" s))]
    (is (= 42 (evm-sized (with-meta {} {(k "evm-sized") (fn [_] 42)}))) "meta_dispatch")
    (is (false? (satisfies? EvmSized (with-meta {} {(k "evm-sized") (fn [_] 42)})))
        "satisfies_ignores_meta")
    (is (= [:meta-wins :extend]
           [(evm-vsized (with-meta [] {(k "evm-vsized") (fn [_] :meta-wins)})) (evm-vsized [])])
        "meta_beats_extend")
    (is (= [:extend :meta :extend]
           [(evm-msized {}) (evm-msized (with-meta {} {(k "evm-msized") (fn [_] :meta)})) (evm-msized {})])
        "cache_bypass: per-value metadata does not poison the per-type cache")
    (is (thrown? Throwable (evm-psize (with-meta {} {(k "evm-psize") (fn [_] 99)})))
        "flag_gates: no flag, no metadata dispatch")))

;; ---- tokenizer long input (u16 column / token length overflow) ----

(deftest tokenizer-long-input
  (is (= 42 (load-string (str ";; " (apply str (repeat 80000 "x")) "\n(+ 40 2)")))
      "tok-long-line-no-panic: a line past 65535 columns")
  (is (= 70000 (count (read-string (str "\"" (apply str (repeat 70000 "a")) "\""))))
      "tok-long-token-no-panic: a token past 65535 chars, not truncated"))

;; ---- BFS queue GC pin (D-556 class) ----

(def ^:private bfs-fixture "test/clj/fixtures/bfs_queue_gc.clj")
(def ^:private bfs-won "WON path= [3 3 3 3 3 3 3 3 3 3]")

(deftest bfs-queue-gc
  (is (= bfs-won (str/trim (with-out-str (load-file bfs-fixture)))) "bfs_queue_default")
  (is (= bfs-won (str/trim (:out (sh "zig-out/bin/cljw" bfs-fixture
                                     :env (assoc (into {} (System/getenv)) "CLJW_GC_THRESHOLD_MB" "1")))))
      "bfs_queue_thr1mb: frequent collects"))
