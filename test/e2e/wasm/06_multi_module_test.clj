;; 06_multi_module_test.clj — E2E test: multi-module linking (Phase 36.8)
;; Verifies: cross-module function imports via wasm/load :imports option

(require '[cljw.wasm :as wasm])

;; Part 1: Two modules — math exports add/mul, app imports them
(def math-mod (wasm/load "src/wasm/testdata/20_math_export.wasm"))

;; Verify math standalone
(def add (wasm/fn math-mod "add"))
(def mul (wasm/fn math-mod "mul"))
(assert (= 7 (add 3 4)) "math add(3,4) should be 7")
(assert (= 12 (mul 3 4)) "math mul(3,4) should be 12")

;; Load app with math as import source
(def app-mod (wasm/load "src/wasm/testdata/21_app_import.wasm"
                        {:imports {"math" math-mod}}))
(def add-and-mul (wasm/fn app-mod "add_and_mul"))

;; add_and_mul(3, 4, 5) = (3 + 4) * 5 = 35
(assert (= 35 (add-and-mul 3 4 5)) "add_and_mul(3,4,5) should be 35")
(assert (= 20 (add-and-mul 1 3 5)) "add_and_mul(1,3,5) should be 20")
(assert (= 0 (add-and-mul 5 -5 100)) "add_and_mul(5,-5,100) should be 0")

;; Part 2: Three module chain — base→mid→top
(def base-mod (wasm/load "src/wasm/testdata/22_base.wasm"))
(def double (wasm/fn base-mod "double"))
(assert (= 10 (double 5)) "double(5) should be 10")

(def mid-mod (wasm/load "src/wasm/testdata/23_mid.wasm"
                        {:imports {"base" base-mod}}))
(def quadruple (wasm/fn mid-mod "quadruple"))
(assert (= 20 (quadruple 5)) "quadruple(5) should be 20")
(assert (= 40 (quadruple 10)) "quadruple(10) should be 40")

(def top-mod (wasm/load "src/wasm/testdata/24_top.wasm"
                        {:imports {"mid" mid-mod}}))
(def octuple (wasm/fn top-mod "octuple"))
(assert (= 24 (octuple 3)) "octuple(3) should be 24")
(assert (= 80 (octuple 10)) "octuple(10) should be 80")

(println "PASS: 06_multi_module_test")
