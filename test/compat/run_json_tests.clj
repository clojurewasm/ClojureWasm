;; clojure.data.json compatibility test for CW
;; Based on upstream clojure/data.json test suite
;; Tests read-str and write-str (CW fork, no java.io.Reader)

(require '[clojure.data.json :as json])
(require '[clojure.test :refer [deftest is are testing run-tests]])
(require '[clojure.string :as str])

(deftest read-numbers
  (is (= 42 (json/read-str "42")))
  (is (= -3 (json/read-str "-3")))
  (is (= 3.14159 (json/read-str "3.14159")))
  (is (= 6.022e23 (json/read-str "6.022e23"))))

(deftest read-bigint
  (is (= 123456789012345678901234567890N
         (json/read-str "123456789012345678901234567890"))))

(deftest read-bigdec
  (is (= 3.14159M (json/read-str "3.14159" :bigdec true))))

(deftest read-null
  (is (= nil (json/read-str "null"))))

(deftest read-strings
  (is (= "Hello, World!" (json/read-str "\"Hello, World!\""))))

(deftest escaped-slashes-in-strings
  (is (= "/foo/bar" (json/read-str "\"\\/foo\\/bar\""))))

(deftest unicode-escapes
  (is (= " \u0beb " (json/read-str "\" \\u0bEb \""))))

(deftest escaped-whitespace
  (is (= "foo\nbar" (json/read-str "\"foo\\nbar\"")))
  (is (= "foo\rbar" (json/read-str "\"foo\\rbar\"")))
  (is (= "foo\tbar" (json/read-str "\"foo\\tbar\""))))

(deftest read-booleans
  (is (= true (json/read-str "true")))
  (is (= false (json/read-str "false"))))

(deftest ignore-whitespace
  (is (= nil (json/read-str "\r\n   null"))))

(deftest read-arrays
  (is (= (vec (range 35))
         (json/read-str "[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34]")))
  (is (= ["Ole" "Lena"] (json/read-str "[\"Ole\", \r\n \"Lena\"]"))))

(deftest read-objects
  (is (= {:k1 1, :k2 2, :k3 3, :k4 4, :k5 5, :k6 6, :k7 7, :k8 8
          :k9 9, :k10 10, :k11 11, :k12 12, :k13 13, :k14 14, :k15 15, :k16 16}
         (json/read-str "{\"k1\": 1, \"k2\": 2, \"k3\": 3, \"k4\": 4,
                          \"k5\": 5, \"k6\": 6, \"k7\": 7, \"k8\": 8,
                          \"k9\": 9, \"k10\": 10, \"k11\": 11, \"k12\": 12,
                          \"k13\": 13, \"k14\": 14, \"k15\": 15, \"k16\": 16}"
                        :key-fn keyword))))

(deftest read-nested-structures
  (is (= {:a [1 2 {:b [3 "four"]} 5.5]}
         (json/read-str "{\"a\":[1,2,{\"b\":[3,\"four\"]},5.5]}"
                        :key-fn keyword))))

(deftest reads-long-string-correctly
  (let [long-string (str/join "" (take 100 (cycle "abcde")))]
    (is (= long-string (json/read-str (str "\"" long-string "\""))))))

(deftest disallows-non-string-keys
  (is (thrown? Exception (json/read-str "{26:\"z\""))))

(deftest disallows-barewords
  (is (thrown? Exception (json/read-str "  foo  "))))

(deftest disallows-unclosed-arrays
  (is (thrown? Exception (json/read-str "[1, 2,  "))))

(deftest disallows-unclosed-objects
  (is (thrown? Exception (json/read-str "{\"a\":1,  "))))

(deftest disallows-empty-entry-in-object
  (is (thrown? Exception (json/read-str "{\"a\":1,}")))
  (is (thrown? Exception (json/read-str "{\"a\":1, }")))
  (is (thrown? Exception (json/read-str "{\"a\":1,,,,}")))
  (is (thrown? Exception (json/read-str "{\"a\":1,,\"b\":2}"))))

(deftest get-string-keys
  (is (= {"a" [1 2 {"b" [3 "four"]} 5.5]}
         (json/read-str "{\"a\":[1,2,{\"b\":[3,\"four\"]},5.5]}"))))

(deftest keywordize-keys
  (is (= {:a [1 2 {:b [3 "four"]} 5.5]}
         (json/read-str "{\"a\":[1,2,{\"b\":[3,\"four\"]},5.5]}"
                        :key-fn keyword))))

(deftest omit-values
  (is (= {:number 42}
         (json/read-str "{\"number\": 42, \"date\": \"1955-07-12\"}"
                        :key-fn keyword
                        :value-fn (fn thisfn [k v]
                                    (if (= :date k)
                                      thisfn
                                      v)))))
  (is (= "{\"c\":1,\"e\":2}"
         (json/write-str (sorted-map :a nil, :b nil, :c 1, :d nil, :e 2, :f nil)
                         :value-fn (fn remove-nils [k v]
                                     (if (nil? v)
                                       remove-nils
                                       v))))))

(def pass1-string
  "[
    \"JSON Test Pattern pass1\",
    {\"object with 1 member\":[\"array with 1 element\"]},
    {},
    [],
    -42,
    true,
    false,
    null,
    {
        \"integer\": 1234567890,
        \"real\": -9876.543210,
        \"e\": 0.123456789e-12,
        \"E\": 1.234567890E+34,
        \"\":  23456789012E66,
        \"zero\": 0,
        \"one\": 1,
        \"space\": \" \",
        \"quote\": \"\\\"\",
        \"backslash\": \"\\\\\",
        \"controls\": \"\\b\\f\\n\\r\\t\",
        \"slash\": \"/ & \\/\",
        \"alpha\": \"abcdefghijklmnopqrstuvwyz\",
        \"ALPHA\": \"ABCDEFGHIJKLMNOPQRSTUVWYZ\",
        \"digit\": \"0123456789\",
        \"0123456789\": \"digit\",
        \"special\": \"`1~!@#$%^&*()_+-={':[,]}|;.</>?\",
        \"hex\": \"\\u0123\\u4567\\u89AB\\uCDEF\\uabcd\\uef4A\",
        \"true\": true,
        \"false\": false,
        \"null\": null,
        \"array\":[  ],
        \"object\":{  },
        \"address\": \"50 St. James Street\",
        \"url\": \"http://www.JSON.org/\",
        \"comment\": \"// /* <!-- --\",
        \"# -- --> */\": \" \",
        \" s p a c e d \" :[1,2 , 3

,

4 , 5        ,          6           ,7        ],\"compact\":[1,2,3,4,5,6,7],
        \"jsontext\": \"{\\\"object with 1 member\\\":[\\\"array with 1 element\\\"]}\",
        \"quotes\": \"&#34; \\u0022 %22 0x22 034 &#x22;\",
        \"\\/\\\\\\\"\\uCAFE\\uBABE\\uAB98\\uFCDE\\ubcda\\uef4A\\b\\f\\n\\r\\t`1~!@#$%^&*()_+-=[]{}|;:',./<>?\"
: \"A key can be any string\"
    },
    0.5 ,98.6
,
99.44
,

1066,
1e1,
0.1e1,
1e-1,
1e00,2e+00,2e-00
,\"rosebud\"]")

(deftest pass1-test
  (let [input (json/read-str pass1-string)]
    (is (= "JSON Test Pattern pass1" (first input)))
    (is (= "array with 1 element" (get-in input [1 "object with 1 member" 0])))
    (is (= 1234567890 (get-in input [8 "integer"])))
    (is (= "rosebud" (last input)))))

;;; Write tests

(deftest print-json-strings
  (is (= "\"Hello, World!\"" (json/write-str "Hello, World!")))
  (is (= "\"\\\"Embedded\\\" Quotes\"" (json/write-str "\"Embedded\" Quotes"))))

(deftest print-unicode
  (is (= "\"\\u1234\\u4567\"" (json/write-str "\u1234\u4567"))))

(deftest print-json-null
  (is (= "null" (json/write-str nil))))

(deftest print-ratios-as-doubles
  (is (= "0.75" (json/write-str 3/4))))

(deftest print-bigints
  (is (= "12345678901234567890" (json/write-str 12345678901234567890))))

(deftest write-bigint
  (is (= "123456789012345678901234567890"
         (json/write-str 123456789012345678901234567890N))))

(deftest write-bigdec
  (is (= "3.14159" (json/write-str 3.14159M))))

(deftest print-json-arrays
  (is (= "[1,2,3]" (json/write-str [1 2 3])))
  (is (= "[1,2,3]" (json/write-str (list 1 2 3))))
  (is (= "[1,2,3]" (json/write-str (sorted-set 1 2 3))))
  (is (= "[1,2,3]" (json/write-str (seq [1 2 3])))))

(deftest print-empty-arrays
  (is (= "[]" (json/write-str [])))
  (is (= "[]" (json/write-str (list))))
  (is (= "[]" (json/write-str #{}))))

(deftest print-json-objects
  (is (= "{\"a\":1,\"b\":2}" (json/write-str (sorted-map :a 1 :b 2)))))

(deftest object-keys-must-be-strings
  (is (= "{\"1\":1,\"2\":2}" (json/write-str (sorted-map 1 1 2 2)))))

(deftest print-empty-objects
  (is (= "{}" (json/write-str {}))))

(deftest accept-sequence-of-nils
  (is (= "[null,null,null]" (json/write-str [nil nil nil]))))

(deftest error-on-nil-keys
  (is (thrown? Exception (json/write-str {nil 1}))))

(deftest default-throws-on-eof
  (is (thrown? Exception (json/read-str ""))))

(deftest accept-eof
  (is (= ::eof (json/read-str "" :eof-error? false :eof-value ::eof))))

(deftest characters-in-map-keys-are-escaped
  (is (= "{\"\\\"\":42}" (json/write-str {"\"" 42}))))

(deftest lenient-on-extra-data
  (is (= [42] (json/read-str "[42],abc"))))

;;; Indent tests

(deftest print-json-arrays-indent
  (is (= "[\n  1,\n  2,\n  3\n]" (json/write-str [1 2 3] :indent true)))
  (is (= "[\n  1,\n  2,\n  3\n]" (json/write-str (list 1 2 3) :indent true)))
  (is (= "[\n  1,\n  2,\n  3\n]" (json/write-str (sorted-set 1 2 3) :indent true)))
  (is (= "[\n  1,\n  2,\n  3\n]" (json/write-str (seq [1 2 3]) :indent true))))

(deftest print-empty-arrays-indent
  (is (= "[]" (json/write-str [] :indent true)))
  (is (= "[]" (json/write-str (list) :indent true)))
  (is (= "[]" (json/write-str #{} :indent true))))

(deftest print-json-objects-indent
  (is (= "{\n  \"a\": 1,\n  \"b\": 2\n}" (json/write-str (sorted-map :a 1 :b 2) :indent true))))

(deftest print-empty-objects-indent
  (is (= "{}" (json/write-str {} :indent true))))

(deftest print-json-nested-indent
  (is (=
       "{\n  \"a\": {\n    \"b\": [\n      1,\n      2\n    ],\n    \"c\": [],\n    \"d\": {}\n  }\n}"
       (json/write-str {:a (sorted-map :b [1 2] :c [] :d {})} :indent true))))

;;; UUID test
(deftest print-uuids
  (let [uid (random-uuid)
        json-str (json/write-str uid)
        parsed (json/read-str json-str)]
    (is (string? parsed))
    (is (= (str uid) parsed))))

;;; Escape tests
(deftest print-nonescaped-unicode
  (is (= "\"\\u0000\\t\\u001f \"" (json/write-str "\u0000\u0009\u001f\u0020" :escape-unicode true)))
  (is (= "\"\\u0000\\t\\u001f \"" (json/write-str "\u0000\u0009\u001f\u0020" :escape-unicode false))))

(deftest escape-special-separators
  (is (= "\"\\u2028\\u2029\"" (json/write-str "\u2028\u2029" :escape-unicode false)))
  (is (= "\"\u2028\u2029\"" (json/write-str "\u2028\u2029" :escape-js-separators false))))

;;; NaN/Infinity tests
(deftest error-on-NaN
  (is (thrown? Exception (json/write-str ##NaN))))

(deftest error-on-infinity
  (is (thrown? Exception (json/write-str ##Inf)))
  (is (thrown? Exception (json/write-str ##-Inf))))

;;; Run all tests
(let [result (run-tests)]
  (println "\nResult:" result)
  (when (or (pos? (:fail result)) (pos? (:error result)))
    (System/exit 1)))
