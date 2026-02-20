;; CLJW-ADD: Tests for CW Java interop class implementations
;; StringBuilder, StringWriter, PushbackReader, BufferedWriter, URI, File, UUID

(ns clojure.test-clojure.interop-classes
  (:require [clojure.test :refer [deftest is testing run-tests]])
  (:import (java.net URI)
           (java.util UUID)))

;; ========== StringBuilder ==========

(deftest test-string-builder
  (testing "basic append and toString"
    (let [sb (StringBuilder.)]
      (.append sb "hello")
      (.append sb " ")
      (.append sb "world")
      (is (= "hello world" (.toString sb)))))
  (testing "append returns this"
    (let [sb (StringBuilder.)]
      (is (= sb (.append sb "x")))))
  (testing "length"
    (let [sb (StringBuilder.)]
      (.append sb "abc")
      (is (= 3 (.length sb)))))
  (testing "close then use gives error"
    (let [sb (StringBuilder.)]
      (.append sb "hello")
      (.close sb)
      (is (thrown? Exception (.append sb " world")))))
  (testing "double close is safe"
    (let [sb (StringBuilder.)]
      (.close sb)
      (.close sb)
      (is true))))

;; ========== StringWriter ==========

(deftest test-string-writer
  (testing "write and toString"
    (let [sw (StringWriter.)]
      (.write sw "hello")
      (is (= "hello" (.toString sw)))))
  (testing "write integer (code point)"
    (let [sw (StringWriter.)]
      (.write sw 65) ; 'A'
      (is (= "A" (.toString sw)))))
  (testing "append returns this"
    (let [sw (StringWriter.)]
      (is (= sw (.append sw "x")))))
  (testing "close then use"
    (let [sw (StringWriter.)]
      (.write sw "hello")
      (.close sw)
      (is (thrown? Exception (.write sw " world"))))))

;; ========== PushbackReader ==========

(deftest test-pushback-reader
  (testing "basic read"
    (let [pr (PushbackReader. (StringReader. "abc"))]
      (is (= 97 (.read pr)))  ; 'a'
      (is (= 98 (.read pr)))  ; 'b'
      (is (= 99 (.read pr)))  ; 'c'
      (is (= -1 (.read pr))))) ; EOF
  (testing "unread"
    (let [pr (PushbackReader. (StringReader. "ab"))]
      (is (= 97 (.read pr)))
      (.unread pr 97)
      (is (= 97 (.read pr)))
      (is (= 98 (.read pr)))))
  (testing "readLine"
    (let [pr (PushbackReader. (StringReader. "hello\nworld"))]
      (is (= "hello" (.readLine pr)))
      (is (= "world" (.readLine pr)))
      (is (nil? (.readLine pr)))))
  (testing "ready"
    (let [pr (PushbackReader. (StringReader. "x"))]
      (is (.ready pr))
      (.read pr)
      (is (not (.ready pr)))))
  (testing "close then use"
    (let [pr (PushbackReader. (StringReader. "abc"))]
      (.read pr)
      (.close pr)
      (is (thrown? Exception (.read pr))))))

;; ========== URI ==========

(deftest test-uri
  (testing "URI construction and methods"
    (let [u (URI. "https://example.com:8080/path?q=1#frag")]
      (is (= "https" (.getScheme u)))
      (is (= "example.com" (.getHost u)))
      (is (= 8080 (.getPort u)))
      (is (= "/path" (.getPath u)))
      (is (= "q=1" (.getQuery u)))
      (is (= "frag" (.getFragment u)))))
  (testing "toString"
    (let [u (URI. "https://example.com")]
      (is (= "https://example.com" (.toString u)))))
  (testing "instance?"
    ;; CLJW: wrap in true? — is macro has bug with instance? special form reporting
    (is (true? (instance? URI (URI. "http://x.com"))))))

;; ========== UUID ==========

(deftest test-uuid
  (testing "random UUID"
    (let [u (UUID/randomUUID)]
      ;; CLJW: wrap in true? — is macro has bug with instance? special form reporting
      (is (true? (instance? UUID u)))
      (is (string? (.toString u)))
      (is (= 36 (count (.toString u))))))
  (testing "from string"
    (let [s "550e8400-e29b-41d4-a716-446655440000"
          u (UUID/fromString s)]
      (is (= s (.toString u)))))
  (testing "two random UUIDs are different"
    (is (not= (.toString (UUID/randomUUID))
              (.toString (UUID/randomUUID))))))

(run-tests)
