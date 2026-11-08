;; D-567 / D-404: a component with more than one export loads (zwasm rejected
;; any component with >= 2 exports with InvalidSort until zwasm #157), and the
;; ADR-0135 WIT <-> Clojure marshalling table round-trips through the
;; 16-export `echo` fixture. Every row is an ECHO, so a passing case proves
;; lower AND lift agree: a one-directional check would pass on two mistakes
;; that cancel. Provenance of the fixtures: test/e2e/fixtures/wasm/README_echo.md.
;; Needs the -Dwasm binary.
;;
;; Migrated from test/e2e/phase16_wasm_component_multiexport.sh and its
;; wasm_marshalling_table.clj fixture.
(ns suites.wasm-component-multiexport-test
  (:require [clojure.test :refer [deftest is testing]]))

(def ^:private fx "test/e2e/fixtures/wasm/")
(def ^:private echo (str fx "echo.component.wasm"))

(deftest multi-export-components-load
  (is (= 1 (count (wasm/component-exports (str fx "greet_component.wasm"))))
      "single-export-control")
  (is (= 2 (count (wasm/component-exports (str fx "two_export_component.wasm"))))
      "two-export-loads: the minimal D-567 reproduction")
  (is (= 16 (count (wasm/component-exports echo)))
      "typed-fixture-lists-all-exports"))

(defmacro ^:private echoes [f & vs]
  `(do ~@(for [v vs] `(is (= ~v (wasm/component-invoke echo ~f ~v)) (str ~f " " (pr-str ~v))))))

(deftest adr0135-marshalling-table-round-trips
  (testing "scalars"
    (echoes "echo-bool" true)
    (echoes "echo-s32" -7)
    (echoes "echo-u64" 12345)
    (echoes "echo-f32" 0.5)
    (echoes "echo-f64" 1.5))
  (testing "char is a 21-bit code point, so an astral-plane scalar binds (ADR-0135 am2)"
    (echoes "echo-char" \a (char 0x10437)))
  (testing "string: the first row needing linear memory + cabi_realloc"
    (echoes "echo-string" "hi"))
  (testing "enum -> keyword (a case NAME, not an ordinal)"
    (echoes "echo-colour" :green))
  (testing "option -> nil | v"
    (echoes "echo-option-u32" 9 nil))
  (testing "list -> vector; flags -> set of keywords; tuple -> vector; record -> map"
    (echoes "echo-list-u32" [1 2 3])
    (echoes "echo-perms" #{:read :exec})
    (echoes "echo-tuple" [7 "x"])
    (echoes "echo-pair" {:n 3 :label "p"}))
  (testing "result and variant as tagged vectors (their LOWER side raised until 2026-08-04)"
    (echoes "echo-result" [:ok 7] [:err "boom"])
    (echoes "echo-shape" [:circle 1.5] [:square 3]))
  (testing "a payload-less variant case is [:tag], not [:tag nil]"
    (echoes "echo-shape" [:point])))
