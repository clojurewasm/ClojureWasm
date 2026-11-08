;; Capture groups past the former inline cap. The Pike VM used to carry a fixed
;; [16]i32 slot array per thread (8 slot pairs, pair 0 unused), so a pattern
;; with 8+ capturing groups failed to compile with a misleading
;; "backreferences / an unsupported construct" error. Slots are now sized per
;; program, bounded only by compile.MAX_CAPTURE_GROUPS (1024).
;;
;; Pins: the Emmy complex-number pattern (emmy/complex/impl.cljc:149) through
;; re-matches / re-find / re-seq / re-groups / the Matcher API; wide, nested and
;; optional (unmatched -> nil) groups; and too many groups as a catchable
;; resource error naming the limit. The backreference half of the error split
;; is UNCATCHABLE (AD-060), so it is a process-boundary check and lives in
;; test/e2e/regex_parity_gaps.sh.
(ns suites.regex-many-groups-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]))

(def emmy-re
  #"([+-]?\d+(\.\d*)?([Ee][+-]?\d+)?)(\s?([+-])?\s?([+-]?\d+(\.\d*)?([Ee][+-]?\d+)?)[Ii])?")

(deftest emmy-pattern
  (is (= [["1+2i" "1" nil nil "+2i" "+" "2" nil nil]
          ["-3.5e2 - 4I" "-3.5e2" ".5" "e2" " - 4I" "-" "4" nil nil]
          ["7" "7" nil nil nil nil nil nil nil]]
         (mapv #(re-matches emmy-re %) ["1+2i" "-3.5e2 - 4I" "7"]))
      "emmy_re_matches")
  (let [m (re-matcher emmy-re "z=1+2i")]
    (.find m)
    (is (= [["1+2i" "1" nil nil "+2i" "+" "2" nil nil] 8 "2" nil
            ["1+2i" "1" nil nil "+2i" "+" "2" nil nil]]
           [(re-find emmy-re "z=1+2i") (.groupCount m) (.group m 6) (.group m 8)
            (re-groups m)])
        "emmy_re_find_and_matcher")))

(deftest twelve-groups
  (let [re #"(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)"
        s (re-seq re "abcdefghijkl-abcdefghijkl")
        m (doto (re-matcher re "abcdefghijkl") .matches)]
    (is (= [["abcdefghijkl" "a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l"] 2 "l" "l"]
           [(first s) (count s) (.group m 12) (nth m 12)])
        "twelve_groups_re_seq")))

(deftest nested-optional
  (let [re #"(((((((((x)))))))))(z)?(y)"]
    (is (= [["xy" "x" "x" "x" "x" "x" "x" "x" "x" "x" nil "y"]
            ["xzy" "x" "x" "x" "x" "x" "x" "x" "x" "x" "z" "y"]]
           [(re-find re "xy") (re-find re "xzy")])
        "nested_optional")))

(deftest replace-dollar-nine
  (is (= "i-a" (str/replace "abcdefghi" #"(a)(b)(c)(d)(e)(f)(g)(h)(i)" "$9-$1"))
      "replace_dollar_nine"))

(deftest thousand-groups
  (let [re (re-pattern (apply str (repeat 1000 "(x)")))
        m (re-matches re (apply str (repeat 1000 "x")))]
    (is (= [1000 "x"] [(dec (count m)) (peek m)]) "thousand_groups")))

(deftest too-many-groups
  (let [msg (try (re-pattern (apply str (repeat 1025 "()"))) :NOT-RAISED
                 (catch Exception e (.getMessage e)))]
    (is (string? msg) "too_many_groups: raised a catchable exception")
    (is (and (string? msg)
             (str/includes? msg "too many capturing groups (more than 1024)"))
        "too_many_groups: message names the limit")))
