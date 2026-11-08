;; test/e2e/phase14_map_string_keys.sh
;;
;; D-151 cycle 1 — map lookup keys non-interned STRING keys by value
;; (byte-equality), not by identity. `keyEqValue` in runtime/equal.zig,
;; routed from map.zig + transient_array_map.zig keyEq. array_map only
;; (≤8 entries; the HAMT path is D-045-deferred so >8 raises explicitly).
;;
;; Keys by `=` semantics (category-based: `{1 :a}` vs `1.0` → nil),
;; matching JVM. Also unblocks `:strs` map-destructuring (D-076).

;; Migrated from test/e2e/phase14_map_string_keys.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.map-string-keys-test
  (:require [clojure.test :refer [deftest is]]))

(deftest map-string-keys-cases
  (is (= "5" (pr-str (get {"x" 5} "x"))) "get_string_key")
  (is (= "true" (pr-str (contains? {"x" 5} "x"))) "contains_string")
  (is (= "nil" (pr-str (get {"x" 5} "y"))) "get_string_miss")
  (is (= "9" (pr-str (get (assoc {"k" 1} "k" 9) "k"))) "assoc_replace")
  (is (= "2" (pr-str (get {"a" 1 "b" 2 "c" 3} "b"))) "multi_string_key")
  (is (= "nil" (pr-str (get {1 :a} 1.0))) "cat_int_float")
  (is (= ":a" (pr-str (get {1 :a} 1))) "int_key_ok")
  (is (= "1" (pr-str (get {:a 1} :a))) "kw_key_ok")
  (is (= "true" (pr-str (= {"x" 1 "y" 2} {"y" 2 "x" 1}))) "map_eq_strkeys")
  (is (= "\"bob\"" (pr-str (let [{:strs [name]} {"name" "bob"}] name))) "strs_destructure"))
