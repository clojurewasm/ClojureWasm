;; [CLJW-NUMBER-TOKEN-END]: a number token runs to the next delimiter.
;;
;; clj LispReader.readNumber consumes the whole run up to whitespace or a macro
;; char and rejects it when it matches no number pattern. cljw's tokenizer used
;; to stop at the first character that did not continue the number, so
;; `(read-string "12x")` was 12 and `[1/2x]` read as `[1/2 x]`. Every literal
;; kind was affected. The messages below are clj's, checked against
;; Clojure 1.12.4.
(ns suites.number-token-end-test
  (:require [clojure.edn :as edn]
            [clojure.test :refer [deftest is testing]]))

(deftest non-number-run-is-rejected-whole
  (doseq [src ["12x" "1.5x" "1/2x" "1/2/3" "4/-2" "12N3" "1.5N" "1.5.3"
               "2r" "0x1g" "+12x" "1.5Mx" "09"]]
    (testing src
      (is (thrown-with-msg? NumberFormatException
                            (re-pattern (str "Invalid number: \\Q" src "\\E"))
                            (read-string src))))))

(deftest edn-reader-rejects-the-same-run
  (is (thrown-with-msg? NumberFormatException #"Invalid number: 1/2x"
                        (edn/read-string "1/2x"))))

(deftest a-macro-char-ends-a-number
  (is (= [1 #{}] (read-string "[1#{}]")))
  (is (= '[1 (quote a)] (read-string "[1'a]")))
  (is (= '[12 (x)] (read-string "[12(x)]")))
  (is (= '[1 %] (read-string "[1%]"))))

(deftest n-suffix-on-radix-forms
  (is (= 255N (read-string "0xFFN")))
  (is (= 15N (read-string "017N")))
  (is (= -16N (read-string "-0x10N"))))
