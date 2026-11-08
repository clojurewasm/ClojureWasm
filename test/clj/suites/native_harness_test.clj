(ns suites.native-harness-test
  (:require [clojure.test :refer [deftest is testing]]
            [dev.bencode :as bencode]
            [dev.nrepl :as nrepl]
            [harness.corpus :as corpus]))

(defn unsigned-bytes [s]
  (vec (map #(bit-and % 255) (seq (.getBytes s "UTF-8")))))

(deftest shared-bencode-runs-inside-cljw
  (testing "UTF-8 lengths are byte lengths"
    (is (= "9:日本語" (bencode/bstr "日本語"))))
  (let [value {"code" "(+ 1 2)" "id" "7" "op" "eval"}
        encoded (bencode/encode-dict value)
        bytes (unsigned-bytes encoded)
        [decoded consumed] (bencode/decode-all bytes 0)]
    (is (= [value] decoded))
    (is (= (count bytes) consumed))
    (testing "partial frames abstain without consuming their prefix"
      (is (= [[] 0]
             (bencode/decode-all (subvec bytes 0 (dec (count bytes))) 0))))))

(deftest corpus-pairs-ignore-comments-and-preserve-values
  (is (= [{:expr "(+ 1 2)" :want "3"}
          {:expr "(pr-str :x)" :want "\" :x\""}]
         (corpus/parse-pairs
          (str ";; context\n"
               "(+ 1 2)\n;;=> 3\n\n"
               "(pr-str :x)\n;;=> \" :x\"\n")))))

(deftest response-projection-follows-wire-order
  (let [messages [{"out" "a"}
                  {"err" "b"}
                  {"value" "nil"}
                  {"status" ["eval-error"] "ex" "RuntimeException"}]]
    (is (= "ab" (nrepl/response-output messages)))
    (is (true? (nrepl/response-error? messages)))
    (is (false? (nrepl/response-error? [{"status" ["done"]}])))))
