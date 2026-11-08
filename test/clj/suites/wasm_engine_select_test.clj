;; Per-instance zwasm engine selection (zwasm ADR-0200 JIT adoption):
;; `(wasm/load path {:engine :jit|:interp|:auto})` + `wasm/call`. A GPR export
;; is identical jit == interp (the F-012 differential discipline applied to
;; engine choice); a SIMD body runs on the JIT and traps catchably on interp
;; (SIMD is JIT-only, to_cljw_03); the no-opts default rides :auto = JIT
;; (D-488), proven by a SIMD body only the JIT can run. Needs the -Dwasm binary.
;;
;; Migrated from test/e2e/phase16_wasm_engine_select.sh and its
;; jit_engine_select.clj fixture; the probe's labels are the messages.
(ns suites.wasm-engine-select-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]))

(def ^:private fx "test/e2e/fixtures/wasm/")
(def ^:private simd (str fx "jit_simd.wasm"))

(defn- on [path engine] (wasm/load (str fx path) {:engine engine}))

(deftest gpr-and-simd-by-engine
  (let [jit (wasm/load simd {:engine :jit})
        interp (wasm/load simd {:engine :interp})]
    (is (= 5 (wasm/call jit "add" 2 3)) "add-jit")
    (is (= 5 (wasm/call interp "add" 2 3)) "add-interp")
    (is (= 42 (wasm/call jit "lane0")) "lane0-jit: SIMD through the exportFuncSig JIT arm")
    (is (thrown? Throwable (wasm/call interp "lane0")) "lane0-interp: TRAPPED catchably")))

(deftest no-opts-default-rides-the-jit
  (is (= 5 (wasm/call (wasm/load simd) "add" 2 3)) "default")
  (is (= 42 (wasm/call (wasm/load simd) "lane0"))
      "default-simd: an interp default would TRAP on the SIMD body"))

(deftest invoke-shape-marshalling
  (testing "multi-value result -> vector, 2-arg f64 -> double, jit == interp"
    (is (= [3 2] (wasm/call (on "jit_shapes.wasm" :jit) "divmod" 17 5)) "divmod-jit")
    (is (= [3 2] (wasm/call (on "jit_shapes.wasm" :interp) "divmod" 17 5)) "divmod-interp")
    (is (= 3.75 (wasm/call (on "jit_shapes.wasm" :interp) "addf" 1.5 2.25)) "addf-interp")
    (is (= 3.75 (wasm/call (on "jit_shapes.wasm" :jit) "addf" 1.5 2.25)) "addf-jit"))
  (testing "mixed (i32,f64)->f64 (zwasm @3cf40a573)"
    (is (= 5.5 (wasm/call (on "mix.wasm" :jit) "mix" 3 2.5)) "mix-jit")
    (is (= 5.5 (wasm/call (on "mix.wasm" :interp) "mix" 3 2.5)) "mix-interp"))
  (testing "3-arg (f64,f64,f64)->f64 via the generic buffer path"
    (is (== 7 (wasm/call (on "three_f64.wasm" :jit) "sum3" 1.5 2.5 3.0)) "sum3-jit")
    (is (== 7 (wasm/call (on "three_f64.wasm" :interp) "sum3" 1.5 2.5 3.0)) "sum3-interp"))
  (is (= 70 (wasm/call (on "simd_dot.wasm" :jit) "simd_dot"))
      "simd-dot-jit: i32x4.mul (1,2,3,4)*(5,6,7,8) summed"))

(deftest engine-truth-at-the-surface
  ;; ADR-0196: wasm/engine reports the selection a handle was loaded with, and
  ;; a known-gap trap names the export, signature, engine and remedy.
  (is (= :jit (wasm/engine (wasm/load simd {:engine :jit}))) "engine-jit")
  (is (= :interp (wasm/engine (wasm/load simd {:engine :interp}))) "engine-interp")
  (is (= :auto (wasm/engine (wasm/load simd))) "engine-default")
  (let [va (str fx "void_arity.wasm")
        msg (try (wasm/call (wasm/load va) "gpr4_void" 1 2 3 4) "RAN"
                 (catch Throwable e (ex-message e)))]
    (is (str/includes? msg "'gpr4_void' (i32 i32 i32 i32) -> () trapped on the auto (JIT-first) engine")
        "void4-default names the export, signature and engine (D-585)")
    (is (str/includes? msg "load the module with {:engine :interp}") "void4-default carries the remedy")
    (is (nil? (wasm/call (wasm/load va {:engine :interp}) "gpr4_void" 1 2 3 4)) "void4-interp: RAN")))
