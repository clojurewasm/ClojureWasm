;; ADR-0200 JIT-engine adoption — cljw selects the zwasm engine per-instance via
;; `(wasm/load path {:engine :jit/:interp/:auto})`. The module exports a GPR `add`
;; (multi-arg) and a SIMD-body `lane0` (i32x4.extract_lane on a v128.const → 42;
;; SIMD executes JIT-compiled and crosses the scalar boundary).
;;
;; Asserts: (1) the GPR export is byte-identical under :jit and :interp — the F-012
;; differential discipline applied to engine choice; (2) the SIMD export runs on
;; :jit → 42 (end-to-end through wasm/call, which reads exportFuncSig — the JIT arm
;; zwasm shipped @5b6449779 / from_cljw_02); (3) the SIMD export traps a CATCHABLE
;; error on :interp (SIMD is JIT-only in zwasm — confirmed intentional, to_cljw_03);
;; (4) the no-opts default rides :auto = JIT (D-488 flipped 2026-06-22; zwasm
;; v2.0.0-alpha.3 re-landed .auto→JIT): the default GPR add works AND a SIMD body —
;; which ONLY the JIT can execute — returns 42 with NO :engine opt, proving the
;; default is JIT-first (an interp default would TRAP on the SIMD body).
(def w "test/e2e/fixtures/wasm/jit_simd.wasm")

(def jit    (wasm/load w {:engine :jit}))
(def interp (wasm/load w {:engine :interp}))

(println "add-jit:"    (wasm/call jit "add" 2 3))
(println "add-interp:" (wasm/call interp "add" 2 3))
(println "lane0-jit:"  (wasm/call jit "lane0"))
(println "lane0-interp:"
  (try (wasm/call interp "lane0") "RAN"
    (catch Throwable _ "TRAPPED")))
(println "default:" (wasm/call (wasm/load w) "add" 2 3))
;; The no-opts default now rides :auto = JIT. lane0 is a SIMD (v128) body that ONLY
;; the JIT can execute (interp traps), so a no-opts load returning 42 proves the
;; default flipped to JIT-first (D-488, zwasm v2.0.0-alpha.3).
(println "default-simd:" (wasm/call (wasm/load w) "lane0"))

;; JIT invoke-shape marshalling at the surface (to_cljw_02 matrix): a multi-value
;; (>1 scalar) result returns a cljw vector, and a 2-arg f64 FP-bank param/result
;; returns a cljw double — both byte-identical jit==interp. zwasm @d7da97e04 fixed the
;; 2-arg×FP-bank JIT dispatch (from_cljw_03 repro → to_cljw_04). Wider :jit gaps remain
;; (multi-result-with-FP, 3+-arg FP, v128 boundary) — not exercised here.
(def shapes "test/e2e/fixtures/wasm/jit_shapes.wasm")
(def sj (wasm/load shapes {:engine :jit}))
(def si (wasm/load shapes {:engine :interp}))
(println "divmod-jit:"    (wasm/call sj "divmod" 17 5))
(println "divmod-interp:" (wasm/call si "divmod" 17 5))
(println "addf-interp:"   (wasm/call si "addf" 1.5 2.25))
(println "addf-jit:"      (wasm/call sj "addf" 1.5 2.25))

;; Mixed-bank 2-arg: (i32,f64)→f64. zwasm @3cf40a573 made the 1/2-arg JIT invoke matrix
;; complete (the per-combo veneer falls through to the generic buffer thunk), so a mixed
;; i32+f64 param shape now runs JIT-compiled — byte-identical jit==interp.
(def mj (wasm/load "test/e2e/fixtures/wasm/mix.wasm" {:engine :jit}))
(def mi (wasm/load "test/e2e/fixtures/wasm/mix.wasm" {:engine :interp}))
(println "mix-jit:"    (wasm/call mj "mix" 3 2.5))
(println "mix-interp:" (wasm/call mi "mix" 3 2.5))

;; 3-arg FP via the generic buffer path (beyond the 2-arg veneer fast-path) — locks
;; the (f64,f64,f64)→f64 shape jit==interp (to_cljw_05: 3-arg confirmed via buffer).
(println "sum3-jit:"    (wasm/call (wasm/load "test/e2e/fixtures/wasm/three_f64.wasm" {:engine :jit}) "sum3" 1.5 2.5 3.0))
(println "sum3-interp:" (wasm/call (wasm/load "test/e2e/fixtures/wasm/three_f64.wasm" {:engine :interp}) "sum3" 1.5 2.5 3.0))

;; Real SIMD arithmetic on the JIT: i32x4.mul (1,2,3,4)*(5,6,7,8) = (5,12,21,32),
;; horizontal sum = 70 (not just a const lane extract). JIT-only (interp traps).
(println "simd-dot-jit:" (wasm/call (wasm/load "test/e2e/fixtures/wasm/simd_dot.wasm" {:engine :jit}) "simd_dot"))

;; ADR-0196: engine truth at the surface. `wasm/engine` reports the selection a
;; handle was loaded with, and a trap names the export, its signature, the
;; engine and the remedy when the shape is a known gap. `gpr4_void` is the D-585
;; discriminator: a zero-result arity-4 export the JIT cannot dispatch, so it
;; traps on the default and runs on :interp.
(println "engine-jit:" (wasm/engine jit))
(println "engine-interp:" (wasm/engine interp))
(println "engine-default:" (wasm/engine (wasm/load w)))
(def va "test/e2e/fixtures/wasm/void_arity.wasm")
(println "void4-default:"
  (try (wasm/call (wasm/load va) "gpr4_void" 1 2 3 4) "RAN"
    (catch Throwable e (ex-message e))))
(println "void4-interp:"
  (try (wasm/call (wasm/load va {:engine :interp}) "gpr4_void" 1 2 3 4) "RAN"
    (catch Throwable e (ex-message e))))
(println "DONE")
