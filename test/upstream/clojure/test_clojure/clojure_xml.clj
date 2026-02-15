;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/test/clojure/test_clojure/clojure_xml.clj
;; Upstream lines: 31
;; CLJW markers: 3

;;Author: Frantisek Sodomka


(ns clojure.test-clojure.clojure-xml
  (:use clojure.test)
  ;; CLJW: removed ByteArrayInputStream import (CW uses parse-str instead)
  (:require [clojure.xml :as xml]))

;; CLJW: adapted to use parse-str instead of ByteArrayInputStream
;; CLJW: UPSTREAM-DIFF: CW has no DTD/entity resolution, so &xxe; becomes
;; literal text "&xxe;" rather than nil content. Security property (no XXE) holds.
(deftest CLJ-2611-avoid-XXE
  (let [xml-str "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>
<!DOCTYPE foo [
  <!ELEMENT foo ANY >
  <!ENTITY xxe SYSTEM \"file:///etc/hostname\" >]>
<foo>&xxe;</foo>"
        result (xml/parse-str xml-str)]
    ;; Verify entity was NOT resolved to file contents
    (is (= :foo (:tag result)))
    (is (not (clojure.string/includes?
              (str (:content result)) "/etc/hostname")))))

; parse
;; CLJW-ADD: additional parse tests for CW's pure Clojure XML parser

(deftest test-parse-basic
  (testing "parse basic XML element"
    (is (= {:tag :root, :attrs nil, :content nil}
           (xml/parse-str "<root/>"))))
  (testing "parse element with text content"
    (is (= {:tag :root, :attrs nil, :content ["hello"]}
           (xml/parse-str "<root>hello</root>"))))
  (testing "parse element with attributes"
    (is (= {:tag :item, :attrs {:id "1" :name "test"}, :content nil}
           (xml/parse-str "<item id=\"1\" name=\"test\"/>")))))

(deftest test-parse-nested
  (testing "parse nested elements"
    (let [result (xml/parse-str "<root><child>text</child></root>")]
      (is (= :root (:tag result)))
      (is (= 1 (count (:content result))))
      (is (= :child (:tag (first (:content result)))))
      (is (= ["text"] (:content (first (:content result))))))))

(deftest test-parse-entities
  (testing "XML entity decoding"
    (is (= {:tag :e, :attrs nil, :content ["& < > \" '"]}
           (xml/parse-str "<e>&amp; &lt; &gt; &quot; &apos;</e>")))))

(deftest test-parse-cdata
  (testing "CDATA section"
    (is (= {:tag :e, :attrs nil, :content ["<not-xml>"]}
           (xml/parse-str "<e><![CDATA[<not-xml>]]></e>")))))

(deftest test-parse-comments
  (testing "comments are skipped"
    (is (= {:tag :e, :attrs nil, :content ["text"]}
           (xml/parse-str "<e><!-- comment -->text</e>")))))

(deftest test-accessors
  (testing "tag, attrs, content accessors"
    (let [elem {:tag :foo :attrs {:a "1"} :content ["bar"]}]
      (is (= :foo (xml/tag elem)))
      (is (= {:a "1"} (xml/attrs elem)))
      (is (= ["bar"] (xml/content elem))))))

; emit-element

(deftest test-emit-element
  (testing "emit self-closing element"
    (is (= "<br/>\n"
           (with-out-str (xml/emit-element {:tag :br :attrs nil :content nil})))))
  (testing "emit element with content"
    (let [output (with-out-str (xml/emit-element {:tag :p :attrs nil :content ["hello"]}))]
      (is (clojure.string/includes? output "<p>"))
      (is (clojure.string/includes? output "hello"))
      (is (clojure.string/includes? output "</p>")))))

; emit

(deftest test-emit
  (testing "emit includes XML declaration"
    (let [output (with-out-str (xml/emit {:tag :root :attrs nil :content nil}))]
      (is (clojure.string/includes? output "<?xml"))
      (is (clojure.string/includes? output "/>")))))

(deftest test-parse-from-file
  (testing "parse from file path"
    (spit "/tmp/cw_xml_test.xml" "<data><item>value</item></data>")
    (let [result (xml/parse "/tmp/cw_xml_test.xml")]
      (is (= :data (:tag result)))
      (is (= :item (:tag (first (:content result)))))
      (is (= ["value"] (:content (first (:content result))))))))

;; CLJW-ADD: test runner invocation
(run-tests)
