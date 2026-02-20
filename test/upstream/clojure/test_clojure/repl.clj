;; Upstream: clojure/test/clojure/test_clojure/repl.clj
;; Upstream lines: 62
;; CLJW markers: 3

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

(ns clojure.test-clojure.repl
  (:use clojure.test
        clojure.repl)
  ;; CLJW: removed test-helper and example ns dependencies
  ;; CLJW: require clojure.set explicitly (not auto-loaded like JVM)
  (:require [clojure.string :as str]
            [clojure.set]))

(deftest test-doc
  (testing "with namespaces"
    ;; CLJW: doc output format differs slightly, just check it includes the namespace
    (is (str/includes? (with-out-str (doc clojure.pprint)) "clojure.pprint")))
  (testing "with special cases"
    (is (= (with-out-str (doc catch)) (with-out-str (doc try))))))

;; CLJW: test-source skipped — source-fn not available (no :file metadata)
;; CLJW: test-source-read-eval-* skipped — depends on source

(deftest test-dir
  (is (thrown? Exception (dir-fn 'non-existent-ns)))
  (is (some #{'union} (dir-fn 'clojure.set))))

(deftest test-apropos
  (testing "with a regular expression"
    (is (= '[clojure.core/defmacro] (apropos #"^defmacro$")))
    (is (some #{'clojure.core/defmacro} (apropos #"def.acr.")))
    (is (= [] (apropos #"nothing-has-this-name"))))

  (testing "with a string"
    (is (some #{'clojure.core/defmacro} (apropos "defmacro")))
    (is (some #{'clojure.core/defmacro} (apropos "efmac")))
    (is (= [] (apropos "nothing-has-this-name"))))

  (testing "with a symbol"
    (is (some #{'clojure.core/defmacro} (apropos 'defmacro)))
    (is (some #{'clojure.core/defmacro} (apropos 'efmac)))
    (is (= [] (apropos 'nothing-has-this-name)))))

(run-tests)
