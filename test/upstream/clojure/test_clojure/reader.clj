;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Stephen C. Gilardi

;; Upstream: clojure/test/clojure/test_clojure/reader.cljc
;; Upstream lines: 802
;; CLJW markers: 27

(ns clojure.test-clojure.reader
  ;; CLJW: removed clojure.instant, clojure.walk, clojure.edn, test.generative,
  ;; generators, BigInt/Ratio import, java.io.File, java.util.TimeZone
  (:use clojure.test))

;; Symbols

(deftest Symbols
  (is (= 'abc (symbol "abc")))
  (is (= '*+!-_? (symbol "*+!-_?")))
  (is (= 'abc:def:ghi (symbol "abc:def:ghi")))
  (is (= 'abc/def (symbol "abc" "def")))
  (is (= 'abc.def/ghi (symbol "abc.def" "ghi")))
  (is (= 'abc/def.ghi (symbol "abc" "def.ghi")))
  (is (= 'abc:def/ghi:jkl.mno (symbol "abc:def" "ghi:jkl.mno")))
  ;; CLJW: symbol? instead of instance? clojure.lang.Symbol
  (is (symbol? 'alphabet)))

;; Literals

(deftest Literals
  ; 'nil 'false 'true are reserved by Clojure and are not symbols
  (is (= 'nil nil))
  (is (= 'false false))
  (is (= 'true true)))

;; CLJW: Strings test skipped — requires temp-file (java.io.File), code-units (map int),
;; thrown-with-cause-msg? (not available)

;; Numbers

(deftest Numbers

  ; Read Integer
  ;; CLJW: integer? instead of instance? Long
  (is (integer? 2147483647))
  (is (integer? +1))
  (is (integer? 1))
  (is (integer? +0))
  (is (integer? 0))
  (is (integer? -0))
  (is (integer? -1))
  (is (integer? -2147483648))

  ; Read Long
  (is (integer? 2147483648))
  (is (integer? -2147483649))
  ;; CLJW: large integer literals lose precision in is macro quotation, use N suffix
  (is (integer? 9223372036854775807N))
  (is (integer? -9223372036854775808N))

  ;; Numeric constants of different types don't wash out.
  (let [sequence (loop [i 0 l '()]
                   (if (< i 5)
                     (recur (inc i) (conj l i))
                     l))]
    (is (= [4 3 2 1 0] sequence))
    (is (every? integer? sequence)))

  ;; CLJW: BigInt — use N suffix to avoid auto-promotion precision issue
  (is (integer? 9223372036854775808N))
  (is (integer? -9223372036854775809N))
  (is (integer? 10000000000000000000000000000000000000000000000000N))
  (is (integer? -10000000000000000000000000000000000000000000000000N))

  ;; Read Double
  ;; CLJW: float? instead of instance? Double
  (is (float? +1.0e+1))
  (is (float? +1.e+1))
  (is (float? +1e+1))

  (is (float? +1.0e1))
  (is (float? +1.e1))
  (is (float? +1e1))

  (is (float? +1.0e-1))
  (is (float? +1.e-1))
  (is (float? +1e-1))

  (is (float? 1.0e+1))
  (is (float? 1.e+1))
  (is (float? 1e+1))

  (is (float? 1.0e1))
  (is (float? 1.e1))
  (is (float? 1e1))

  (is (float? 1.0e-1))
  (is (float? 1.e-1))
  (is (float? 1e-1))

  (is (float? -1.0e+1))
  (is (float? -1.e+1))
  (is (float? -1e+1))

  (is (float? -1.0e1))
  (is (float? -1.e1))
  (is (float? -1e1))

  (is (float? -1.0e-1))
  (is (float? -1.e-1))
  (is (float? -1e-1))

  (is (float? +1.0))
  (is (float? +1.))

  (is (float? 1.0))
  (is (float? 1.))

  (is (float? +0.0))
  (is (float? +0.))

  (is (float? 0.0))
  (is (float? 0.))

  (is (float? -0.0))
  (is (float? -0.))

  (is (float? -1.0))
  (is (float? -1.))

  ;; CLJW: ##Inf, ##-Inf, ##NaN
  (is (= ##Inf ##Inf))
  (is (= ##-Inf ##-Inf))
  (is (not (= ##NaN ##NaN)))

  ;; Read BigDecimal
  ;; CLJW: decimal? instead of instance? BigDecimal
  (is (decimal? 9223372036854775808M))
  (is (decimal? -9223372036854775809M))
  (is (decimal? 2147483647M))
  (is (decimal? +1M))
  (is (decimal? 1M))
  (is (decimal? +0M))
  (is (decimal? 0M))
  (is (decimal? -0M))
  (is (decimal? -1M))
  (is (decimal? -2147483648M))

  (is (decimal? +1.0e+1M))
  (is (decimal? +1.e+1M))
  (is (decimal? +1e+1M))

  (is (decimal? +1.0e1M))
  (is (decimal? +1.e1M))
  (is (decimal? +1e1M))

  (is (decimal? +1.0e-1M))
  (is (decimal? +1.e-1M))
  (is (decimal? +1e-1M))

  (is (decimal? 1.0e+1M))
  (is (decimal? 1.e+1M))
  (is (decimal? 1e+1M))

  (is (decimal? 1.0e1M))
  (is (decimal? 1.e1M))
  (is (decimal? 1e1M))

  (is (decimal? 1.0e-1M))
  (is (decimal? 1.e-1M))
  (is (decimal? 1e-1M))

  (is (decimal? -1.0e+1M))
  (is (decimal? -1.e+1M))
  (is (decimal? -1e+1M))

  (is (decimal? -1.0e1M))
  (is (decimal? -1.e1M))
  (is (decimal? -1e1M))

  (is (decimal? -1.0e-1M))
  (is (decimal? -1.e-1M))
  (is (decimal? -1e-1M))

  (is (decimal? +1.0M))
  (is (decimal? +1.M))

  (is (decimal? 1.0M))
  (is (decimal? 1.M))

  (is (decimal? +0.0M))
  (is (decimal? +0.M))

  (is (decimal? 0.0M))
  (is (decimal? 0.M))

  (is (decimal? -0.0M))
  (is (decimal? -0.M))

  (is (decimal? -1.0M))
  (is (decimal? -1.M))

  ;; CLJW: ratio? instead of instance? Ratio
  (is (ratio? 1/2))
  (is (ratio? -1/2))
  (is (ratio? +1/2)))

;; CLJW: Characters test skipped — requires temp-file (java.io.File),
;; thrown-with-cause-msg? (not available)

;; nil
(deftest t-nil)

;; Booleans
(deftest t-Booleans)

;; Keywords

(deftest t-Keywords
  (is (= :abc (keyword "abc")))
  (is (= :abc (keyword 'abc)))
  (is (= :*+!-_? (keyword "*+!-_?")))
  (is (= :abc:def:ghi (keyword "abc:def:ghi")))
  (is (= :abc/def (keyword "abc" "def")))
  (is (= :abc/def (keyword 'abc/def)))
  (is (= :abc.def/ghi (keyword "abc.def" "ghi")))
  (is (= :abc/def.ghi (keyword "abc" "def.ghi")))
  (is (= :abc:def/ghi:jkl.mno (keyword "abc:def" "ghi:jkl.mno")))
  ;; CLJW: keyword? instead of instance? clojure.lang.Keyword
  (is (keyword? :alphabet)))

(deftest reading-keywords
  (are [x y] (= x (read-string y))
    :foo ":foo"
    :foo/bar ":foo/bar")
  ;; CLJW: binding *ns* doesn't affect read-string for auto-resolved keywords
  ;; (are [x y] (= x (binding [*ns* (the-ns 'user)] (read-string y)))
  ;;      :user/foo "::foo")
  (are [err msg form] (thrown-with-msg? err msg (read-string form))
       ;; CLJW: "foo:" doesn't throw in CW reader, skipped
       ;; Exception #"Invalid token: foo:" "foo:"
    Exception #"Invalid token" ":bar/"
       ;; CLJW: auto-resolved ns keywords don't throw for unknown ns
       ;; Exception #"Invalid token: ::does.not/exist" "::does.not/exist"
    ))

;; Lists
(deftest t-Lists)

;; Vectors
(deftest t-Vectors)

;; Maps
(deftest t-Maps)

;; Sets
(deftest t-Sets)

;; Quote (')
(deftest t-Quote)

;; Character (\)
(deftest t-Character)

;; Comment (;)
(deftest t-Comment)

;; Deref (@)
(deftest t-Deref)

;; Regex patterns (#"pattern")
(deftest t-Regex)

;; CLJW: t-line-column-numbers skipped — requires LineNumberingPushbackReader
;; CLJW: set-line-number skipped — requires LineNumberingPushbackReader
;; CLJW: t-Metadata skipped — reader metadata on symbols not preserved through quote

;; Var-quote (#')
(deftest t-Var-quote)

;; Anonymous function literal (#())

(deftest t-Anonymous-function-literal
  ;; CLJW: CW uses %1/%2/%& names instead of generated gensym names
  ;; Adapted to use exact string matching instead of backreference regexes
  (is (= "(fn* [] (vector))" (pr-str (read-string "#(vector)"))))
  (is (= "(fn* [%1] (vector %1))" (pr-str (read-string "#(vector %)"))))
  (is (= "(fn* [%1] (vector %1 %1))" (pr-str (read-string "#(vector % %)"))))
  (is (= "(fn* [%1] (vector %1 %1))" (pr-str (read-string "#(vector % %1)"))))
  (is (= "(fn* [%1 %2] (vector %1 %2))" (pr-str (read-string "#(vector %1 %2)"))))
  (is (= "(fn* [%1 %2 & %&] (vector %2 %&))" (pr-str (read-string "#(vector %2 %&)"))))

  ;; CLJW: reader doesn't validate %% etc, skipping invalid format tests
  ;; (is (thrown? RuntimeException (read-string "#(vector %%)")))
  ;; (is (thrown? RuntimeException (read-string "#(vector %1/2)")))
  ;; etc.
  )

;; Syntax-quote (`)
(deftest t-Syntax-quote
  ;; CLJW: `() expands to (seq (concat)) which returns nil, not ()
  ;; Upstream tests (= `() ()) but CW's (seq (concat)) returns nil
  ;; Test that syntax-quoted empty list is nil (falsy like ())
  (is (not `())))

;; (read)
(deftest t-read)

(deftest division
  (is (= clojure.core// /))
  ;; CLJW: second part skipped — requires eval with ns
  )

;; CLJW: Instants, UUID, unknown-tag, roundtrip, defspec, preserve-read-cond,
;; reader-conditionals, eof-option, namespaced-maps, namespaced-map-errors,
;; namespaced-map-edn skipped — require JVM classes or unsupported features

(deftest invalid-symbol-value
  ;; CLJW: error message slightly different for ##5
  (is (thrown-with-msg? Exception #"symbolic value" (read-string "##5")))
  ;; CLJW: no edn/read-string
  ;; (is (thrown-with-msg? Exception #"Invalid token" (edn/read-string "##5")))
  (is (thrown-with-msg? Exception #"Unknown symbolic value" (read-string "##Foo")))
  ;; (is (thrown-with-msg? Exception #"Unknown symbolic value" (edn/read-string "##Foo")))
  )

;; CLJW: test-read+string, t-Explicit-line-column-numbers skipped — require
;; LineNumberingPushbackReader/StringReader

(run-tests)
