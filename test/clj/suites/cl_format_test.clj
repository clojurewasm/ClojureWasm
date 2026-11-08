;; clojure.pprint/cl-format — the Common Lisp FORMAT directive set (D-403,
;; D-455, D-458, D-465).
;;
;; `(cl-format nil fmt & args)` returns the string. A directive is `~`, an
;; optional parameter list, optional `:` and/or `@` modifiers, then the
;; directive character — and the two modifiers are what most of the surface
;; below is really testing: `~D` vs `~:D` (grouped), `~(` vs `~:(` vs `~@(`
;; vs `~:@(` (four different case rules), `~<` vs `~:<` vs `~@<` (where the
;; padding goes).
;;
;; Parameters can be literal (`~5D`), a quoted char (`~5,'0D`), or resolved at
;; runtime: `V` consumes the next operand as the parameter, `#` is the count of
;; arguments still unprocessed (D-458).
;;
;; Assertions compare the string cl-format returns, which is exactly what the
;; bash script compared through `prn`.
;;
;; Migrated from test/e2e/phase14_cl_format.sh; each assertion keeps its bash
;; case name.
(ns suites.cl-format-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.pprint :as pp]))

(deftest the-base-directives
  (is (= "1 + 2 = 3" (pp/cl-format nil "~a + ~a = ~a" 1 2 3)))  ; aesthetic
  (testing "~S is the READABLE form, so a string keeps its quotes"
    (is (= "\"hi\"" (pp/cl-format nil "~s" "hi"))))             ; standard
  (is (= "42 items" (pp/cl-format nil "~d items" 42)))          ; decimal
  (is (= "a\nb" (pp/cl-format nil "a~%b")))                     ; newline
  (is (= "100~" (pp/cl-format nil "100~~")))                    ; tilde
  (is (= "[x]" (pp/cl-format nil "[~a]" "x"))))                 ; aesthetic-string

(deftest fixed-float-with-a-d-parameter-rounds-to-that-many-places
  (is (= "3.14" (pp/cl-format nil "~,2f" 3.14159)))             ; fixed-float
  (is (= "1.500" (pp/cl-format nil "~,3f" 1.5))))               ; fixed-float-w

;; D-465 — ~F with no d-param prints the NATURAL (shortest round-trip) value in
;; plain fixed notation, always with a decimal point and never scientific
(deftest fixed-float-without-a-d-parameter-is-natural-and-never-scientific
  (is (= "3.14159" (pp/cl-format nil "~F" 3.14159)))            ; float-natural
  (is (= "3.0" (pp/cl-format nil "~F" 3.0)))                    ; float-natural-0
  (testing "an integer operand still gets the point"
    (is (= "42.0" (pp/cl-format nil "~F" 42))))                 ; float-natural-int
  (is (= " 3.14159" (pp/cl-format nil "~8F" 3.14159)))          ; float-natural-w
  (testing "and a magnitude that would print scientific does not"
    (is (= "10000000000.0" (pp/cl-format nil "~F" 1.0e10)))     ; float-natural-big
    (is (= "0.0001" (pp/cl-format nil "~F" 0.0001)))            ; float-natural-small
    (is (= "-10000000000.0" (pp/cl-format nil "~F" -1.0e10))))) ; float-natural-neg

(deftest radix-grouping-and-padding
  (is (= "ff" (pp/cl-format nil "~x" 255)))                     ; hex
  (is (= "100" (pp/cl-format nil "~o" 64)))                     ; octal
  (is (= "1010" (pp/cl-format nil "~b" 10)))                    ; binary
  (testing "the : modifier groups a decimal in threes"
    (is (= "1,000,000" (pp/cl-format nil "~:d" 1000000))))      ; grouped
  (is (= "00042" (pp/cl-format nil "~5,'0d" 42)))               ; zero-padded
  (is (= "******42" (pp/cl-format nil "~8,'*d" 42)))            ; star-padded
  (is (= "    ff" (pp/cl-format nil "~6x" 255))))               ; hex-width

;; ~{…~} applies the enclosed format once per element; ~^ exits before the
;; trailing separator, which is what makes it a JOIN rather than a suffix
(deftest iteration-and-the-escape-that-makes-it-a-join
  (is (= "1, 2, 3" (pp/cl-format nil "~{~a~^, ~}" [1 2 3])))              ; iter-join
  (is (= "[:a | :b | :c]" (pp/cl-format nil "[~{~a~^ | ~}]" [:a :b :c]))) ; iter-around
  (is (= "" (pp/cl-format nil "~{~a~^, ~}" [])))                          ; iter-empty
  (testing "two directives per pass consume two elements per pass"
    (is (= ":x=1 :y=2 " (pp/cl-format nil "~{~a=~a ~}" [:x 1 :y 2])))))   ; iter-pairs

(deftest the-four-case-directives
  (is (= "hello world" (pp/cl-format nil "~(~a~)" "Hello WORLD")))    ; case-lower
  (is (= "Hello World" (pp/cl-format nil "~:(~a~)" "hello world")))   ; case-words
  (is (= "Hello world" (pp/cl-format nil "~@(~a~)" "hello WORLD")))   ; case-first
  (is (= "HELLO WORLD" (pp/cl-format nil "~:@(~a~)" "hello world")))) ; case-upper

(deftest the-numeral-directive
  (is (= "forty-two" (pp/cl-format nil "~r" 42)))                     ; cardinal
  (is (= "one million, two hundred thirty-four thousand, five hundred sixty-seven"
         (pp/cl-format nil "~r" 1234567)))                            ; cardinal-big
  (is (= "forty-second" (pp/cl-format nil "~:r" 42)))                 ; ordinal
  (is (= "XCIX" (pp/cl-format nil "~@r" 99)))                         ; roman
  (testing "with a parameter it is a plain radix instead"
    (is (= "ff" (pp/cl-format nil "~16r" 255)))))                     ; radix

(deftest chars-and-fresh-line
  (is (= "h, e, l, l, o" (pp/cl-format nil "~{~c~^, ~}" "hello")))    ; char_iter
  (is (= "A" (pp/cl-format nil "~C" (char 65))))                      ; char_one
  (is (= "ab\ncd" (pp/cl-format nil "ab~&cd")))                       ; freshline
  (testing "~& is idempotent — it emits a newline only if not already at column 0"
    (is (= "ab\ncd" (pp/cl-format nil "ab~&~&cd")))                   ; fresh_collapse
    (is (= "top" (pp/cl-format nil "~&top"))))                        ; fresh_atstart
  (testing "but ~n& emits n-1 blank lines on top of that"
    (is (= "x\n\n\ny" (pp/cl-format nil "x~3&y")))))                  ; fresh_n

(deftest plural-arg-jump-and-tabulate
  (is (= "1 dog" (pp/cl-format nil "~D dog~:P" 1)))                   ; plural_one
  (is (= "2 dogs" (pp/cl-format nil "~D dog~:P" 2)))                  ; plural_many
  (testing "the @ modifier uses the y/ies rule"
    (is (= "2 puppies" (pp/cl-format nil "~D pupp~:@P" 2))))          ; plural_y
  (is (= "13" (pp/cl-format nil "~a~*~a" 1 2 3)))                     ; star_skip
  (testing "~n@* is an ABSOLUTE jump, not a relative skip"
    (is (= "1 3" (pp/cl-format nil "~a ~2@*~a" 1 2 3))))              ; star_abs
  (is (= "ab        cd" (pp/cl-format nil "ab~10Tcd")))               ; tab_col
  (is (= "abc      z" (pp/cl-format nil "~a~,8T~a" "abc" "z"))))      ; tab_inc

;; ~d,n,w,padchar$ — d digits after the point (2), n before (1), w total (0)
(deftest the-monetary-directive
  (is (= "3.14" (pp/cl-format nil "~$" 3.14159)))                     ; money_basic
  (is (= "5.00" (pp/cl-format nil "~$" 5)))                           ; money_int
  (is (= "0003.14" (pp/cl-format nil "~,4$" 3.14159)))                ; money_npad
  (is (= "    3.14" (pp/cl-format nil "~,,8$" 3.14)))                 ; money_width
  (is (= "+3.14" (pp/cl-format nil "~@$" 3.14)))                      ; money_sign
  (is (= "-3.14" (pp/cl-format nil "~$" -3.14159)))                   ; money_neg
  (is (= "00022.375" (pp/cl-format nil "~3,5$" 22.375)))              ; money_dn
  (is (= " 00022.375" (pp/cl-format nil "~3,5,10$" 22.375)))          ; money_dnw
  (is (= "    +00022.375" (pp/cl-format nil "~3,5,14@$" 22.375)))     ; money_at_w
  (testing "the : modifier moves the sign OUTSIDE the padding"
    (is (= "+    00022.375" (pp/cl-format nil "~3,5,14@:$" 22.375)))) ; money_atcol
  (is (= "1.0" (pp/cl-format nil "~1$" 0.99))))                       ; money_round

(deftest exponential-and-general-float
  (is (= "3.14159E+0" (pp/cl-format nil "~E" 3.14159)))               ; exp_basic
  (is (= "1.2345E+3" (pp/cl-format nil "~E" 1234.5)))                 ; exp_big
  (is (= "  8.000E-1" (pp/cl-format nil "~10,3E" 0.8)))               ; exp_wd
  (testing "rounding can carry into the exponent"
    (is (= "   1.00E+1" (pp/cl-format nil "~10,2E" 9.99999))))        ; exp_round
  (is (= " 1.00E+100" (pp/cl-format nil "~10,2E" 9.99999E99)))        ; exp_e100
  (is (= "-3.14159E+0" (pp/cl-format nil "~E" -3.14159)))             ; exp_neg
  (testing "~G picks fixed or exponential by magnitude, and pads to width either way"
    (is (= "  3.1    " (pp/cl-format nil "~9,2G" 3.14159)))           ; gen_fixed
    (is (= "  3.14E+2" (pp/cl-format nil "~9,2G" 314.159)))           ; gen_exp
    (is (= " 0.800    " (pp/cl-format nil "~10,3G" 0.8)))             ; gen_wd
    (is (= " 0.800    " (pp/cl-format nil "~10,3g" 4/5)))))           ; gen_ratio

(deftest the-conditional-directive
  (testing "a bare ~[ selects the clause the integer operand indexes"
    (is (= "I don't have one" (pp/cl-format nil "I ~[don't ~]have one" 0)))  ; cond_idx0
    (is (= "I have one" (pp/cl-format nil "I ~[don't ~]have one" 1)))        ; cond_idx1
    (is (= "b" (pp/cl-format nil "~[a~;b~;c~]" 1))))                         ; cond_semi
  (testing "~:; is the default clause for an out-of-range index"
    (is (= "d" (pp/cl-format nil "~[a~;b~:;d~]" 9))))                        ; cond_deflt
  (testing "~:[ is the two-clause boolean form"
    (is (= "yes" (pp/cl-format nil "~:[no~;yes~]" true)))                    ; cond_bool
    (is (= "no" (pp/cl-format nil "~:[no~;yes~]" nil))))                     ; cond_boolf
  (testing "~@[ consumes the operand only when it is non-nil"
    (is (= "x" (pp/cl-format nil "x~@[ (~D)~]" nil)))                        ; cond_at_nil
    (is (= "x (7)" (pp/cl-format nil "x~@[ (~D)~]" 7))))                     ; cond_at_val
  (is (= "B 7 ok." (pp/cl-format nil "~[B ~D~:[~; ok~]~;R~]." 0 7 true))))   ; cond_nest

;; ~mincol,colinc,minpad,padchar< — the segments are spread across the width,
;; and the two modifiers decide whether the padding also goes before / after
(deftest the-justification-directive
  (is (= "foobarbaz" (pp/cl-format nil "~<foo~;bar~;baz~>")))                        ; just_none
  (is (= "foo      bar     baz" (pp/cl-format nil "~20<foo~;bar~;baz~>")))           ; just_w
  (is (= "foo  bar  baz" (pp/cl-format nil "~,,2<foo~;bar~;baz~>")))                 ; just_minpad
  (is (= "    foo    bar   baz" (pp/cl-format nil "~20:<~A~;~A~;~A~>" "foo" "bar" "baz")))  ; just_colon
  (is (= "foo    bar    baz   " (pp/cl-format nil "~20@<~A~;~A~;~A~>" "foo" "bar" "baz")))  ; just_at
  (is (= "   foo   bar   baz  " (pp/cl-format nil "~20@:<~A~;~A~;~A~>" "foo" "bar" "baz"))) ; just_atcol
  (is (= "foo barbaz" (pp/cl-format nil "~10,10<~A~;~A~;~A~>" "foo" "bar" "baz")))   ; just_colinc
  (testing "~^ inside a justification drops the segments it never reached"
    (is (= "foo              bar" (pp/cl-format nil "~20<~A~;~^~A~;~^~A~>" "foo" "bar")))))  ; just_caret

;; D-458 — a parameter can be resolved at runtime: V consumes the next operand
;; as the parameter value, # is the count of arguments still unprocessed
(deftest runtime-valued-parameters
  (is (= "   42" (pp/cl-format nil "~VD" 5 42)))                      ; param-V-mincol
  (is (= "***42" (pp/cl-format nil "~V,'*D" 5 42)))                   ; param-V-padchar
  (is (= " 42" (pp/cl-format nil "~#D" 42 0 0)))                      ; param-hash-mincol
  (is (= "ff" (pp/cl-format nil "~VR" 16 255)))                       ; param-V-radix
  (is (= "012.50" (pp/cl-format nil "~,V$" 3 12.5)))                  ; param-V-money
  (testing "V resolves the w and d params of a float independently"
    (is (= " 3.14159" (pp/cl-format nil "~VF" 8 3.14159)))            ; param-V-float
    (is (= "    3.14" (pp/cl-format nil "~8,VF" 2 3.14159)))          ; param-V-float-w
    (is (= "    3.14" (pp/cl-format nil "~V,2F" 8 3.14159)))))        ; param-V-float-d

(deftest a-parameterised-conditional-consumes-no-argument
  (is (= "c" (pp/cl-format nil "~#[a~;b~;c~]" :x :y)))                ; param-hash-select-2
  (is (= "b" (pp/cl-format nil "~#[a~;b~;c~]" :x)))                   ; param-hash-select-1
  (is (= "b" (pp/cl-format nil "~1[a~;b~;c~]"))))                     ; param-n-select

;; the ~<…~:;~> pretty-print column mode needs a pretty writer, which is not
;; built — it must RAISE rather than silently mishandle the directive
(deftest the-unbuilt-column-mode-raises
  (is (thrown? Throwable (pp/cl-format nil "~<a~:;b~>"))))            ; unsupported-raises
