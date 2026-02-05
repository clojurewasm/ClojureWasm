;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Stuart Halloway

;; Upstream: clojure/test/clojure/test_clojure/protocols.clj
;; Upstream lines: 721
;; CLJW markers: 18

;; CLJW: simplified ns — upstream uses external protocol example namespaces,
;; deftype, defrecord, reify, Java imports, and proxy which are not available.
;; Protocol tests use (eval '(do ...)) to enable both VM + TreeWalk backends
;; since eval always routes through TreeWalk internally.
(ns clojure.test-clojure.protocols
  (:use clojure.test))

;; CLJW: skipped protocols-test — requires external protocol examples ns,
;; proxy, reify, var metadata, interface generation (JVM interop).
;; Ported subset: error conditions (below)

;; CLJW: uses thrown-with-msg? instead of thrown-with-cause-msg? (no cause chains)
(deftest test-protocol-error-conditions
  (testing "error conditions checked when defining protocols"
    (is (thrown-with-msg?
         Exception
         #"must take at least one arg"
         (eval '(defprotocol badprotdef (m [])))))
    (is (thrown-with-msg?
         Exception
         #"was redefined"
         (eval '(defprotocol badprotdef (m [this arg]) (m [this arg1 arg2])))))))

;; CLJW: skipped marker-tests — requires defrecord, MarkerProtocol (JVM interop)
;; CLJW: skipped extend-test — requires extend function, deftype (JVM interop)
;; CLJW: skipped record-marker-interfaces — requires defrecord (JVM interop)
;; CLJW: skipped illegal-extending — requires deftype, interface checks (JVM interop)
;; CLJW: skipped defrecord-* tests — requires defrecord (JVM interop)
;; CLJW: skipped deftype-factory-fn — requires deftype (JVM interop)
;; CLJW: skipped hinting-test — requires deftype, type hints (JVM interop)
;; CLJW: skipped reify-test — requires reify (JVM interop)
;; CLJW: skipped test-no-ns-capture — requires top-level protocol forms (JVM interop)
;; CLJW: skipped test-leading-dashes — requires deftype (JVM interop)
;; CLJW: skipped test-longs-hinted-proto — requires reify, longs (JVM interop)
;; CLJW: skipped test-resolve-type-hints — requires import, extend-protocol at ns level (JVM interop)
;; CLJW: skipped test-prim-ret-hints-ignored — requires reify, primitive hints (JVM interop)

;; see CLJ-1879
(deftest test-base-reduce-kv
  (is (= {1 :a 2 :b}
         (reduce-kv #(assoc %1 %3 %2)
                    {}
                    (seq {:a 1 :b 2})))))

;; CLJW-ADD: basic protocol functionality tests via eval
(deftest test-protocol-basic
  (testing "defprotocol + extend-type + dispatch"
    (eval '(do
             (defprotocol BasicTestProto (btp-greet [this]))
             (extend-type String BasicTestProto
                          (btp-greet [this] (str "hello " this)))))
    (is (= "hello world" (eval '(btp-greet "world")))))
  (testing "satisfies? checks"
    (is (true? (eval '(satisfies? BasicTestProto "test"))))
    (is (false? (eval '(satisfies? BasicTestProto 42)))))
  (testing "protocol with multiple methods"
    (eval '(do
             (defprotocol MultiMethodProto
               (mm-first [this])
               (mm-second [this arg]))
             (extend-type Keyword MultiMethodProto
                          (mm-first [this] (name this))
                          (mm-second [this arg] (str (name this) "=" arg)))))
    (is (= "foo" (eval '(mm-first :foo))))
    (is (= "bar=42" (eval '(mm-second :bar 42))))))

;; CLJW-ADD: extend-protocol macro test
(deftest test-extend-protocol
  (testing "extend-protocol with multiple types"
    (eval '(do
             (defprotocol ExtProtoTest (ept-value [this]))
             (extend-protocol ExtProtoTest
               String (ept-value [this] (str "s:" this))
               Keyword (ept-value [this] (str "k:" (name this))))))
    (is (= "s:hello" (eval '(ept-value "hello"))))
    (is (= "k:world" (eval '(ept-value :world))))
    (is (true? (eval '(satisfies? ExtProtoTest "x"))))
    (is (true? (eval '(satisfies? ExtProtoTest :x))))
    (is (false? (eval '(satisfies? ExtProtoTest 42))))))

(run-tests)
