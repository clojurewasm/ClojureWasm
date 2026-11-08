;; test/e2e/fixtures/wasm_marshalling_table.clj — the ADR-0135 WIT<->Clojure
;; mapping table, driven through the 16-export `echo` component fixture.
;;
;; Every row is an ECHO, so a passing case proves lower AND lift agree: a value
;; that survives the round-trip was encoded into the canonical ABI and decoded
;; back. A one-directional check would pass on two mistakes that cancel.
;;
;; Run by test/e2e/phase16_wasm_component_multiexport.sh. Prints MISMATCH lines
;; (the runner greps for them) and TABLE-DONE on completion.
(def p "test/e2e/fixtures/wasm/echo.component.wasm")
(defn ck [f in expect]
  (let [got (wasm/component-invoke p f in)]
    (when-not (= got expect)
      (println "MISMATCH" f "in=" (pr-str in) "got=" (pr-str got) "want=" (pr-str expect)))))

;; scalars
(ck "echo-bool"   true  true)
(ck "echo-s32"    -7    -7)
(ck "echo-u64"    12345 12345)
(ck "echo-f32"    0.5   0.5)
(ck "echo-f64"    1.5   1.5)
;; char is a 21-bit code point in cljw, so an astral-plane scalar binds here
;; where a JVM 16-bit Character cannot (ADR-0135 amendment 2).
(ck "echo-char"   \a    \a)
(ck "echo-char"   (char 0x10437) (char 0x10437))
;; string — the first row needing linear memory + cabi_realloc
(ck "echo-string" "hi"  "hi")
;; enum -> keyword (a case NAME, not an ordinal)
(ck "echo-colour" :green :green)
;; option -> nil | v
(ck "echo-option-u32" 9   9)
(ck "echo-option-u32" nil nil)
;; list -> vector; flags -> set of keywords; tuple -> vector; record -> map
(ck "echo-list-u32" [1 2 3] [1 2 3])
(ck "echo-perms"    #{:read :exec} #{:read :exec})
(ck "echo-tuple"    [7 "x"] [7 "x"])
(ck "echo-pair"     {:n 3 :label "p"} {:n 3 :label "p"})
;; the two sum types, as the tagged vectors ADR-0135 am2 settled. These are the
;; rows whose LOWER side raised feature_not_supported until 2026-08-04, so the
;; shapes the lift produced could not be handed back in.
(ck "echo-result" [:ok 7]       [:ok 7])
(ck "echo-result" [:err "boom"] [:err "boom"])
(ck "echo-shape"  [:circle 1.5] [:circle 1.5])
(ck "echo-shape"  [:square 3]   [:square 3])
;; a payload-less variant case is [:tag], not [:tag nil]
(ck "echo-shape"  [:point]      [:point])
(println "TABLE-DONE")
