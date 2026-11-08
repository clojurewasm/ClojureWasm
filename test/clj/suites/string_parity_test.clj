(ns suites.string-parity-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]))

(deftest replace-coercion-and-empty-match
  (testing "the source uses Object.toString semantics"
    #_{:clj-kondo/ignore [:type-mismatch]}
    (is (= ":bar" (str/replace :foo "foo" "bar")))
    #_{:clj-kondo/ignore [:type-mismatch]}
    (is (= "[:bar]" (str/replace [:foo] "foo" "bar"))))
  (testing "an empty string matches every character boundary"
    (is (= "yxy" (str/replace "x" "" "y")))
    (is (= "yyxyy" (str/replace "x" "" "yy")))))

(deftest split-lines-discards-trailing-empty-fields
  (is (= [""] (str/split-lines "")))
  (is (= [] (str/split-lines "\n\n")))
  (is (= ["foo"] (str/split-lines "foo\n\n")))
  (is (= ["" "bar"] (str/split-lines "\nbar")))
  (is (= ["foo" "" "bar"] (str/split-lines "foo\n\nbar"))))
