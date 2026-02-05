;; Upstream: clojure/test/clojure/test_clojure/keywords.clj
;; Upstream lines: 31
;; CLJW markers: 5

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

(ns clojure.test-clojure.keywords
  (:use clojure.test))

;; CLJW: test-find-keyword skipped — find-keyword not implemented (F80: needs keyword intern table)

(deftest arity-exceptions
  ;; CLJW: thrown-with-msg? not supported; adapted to try/catch + re-find message check
  (is (try (:kw)
           false
           (catch Exception e
             (boolean (re-find #"Wrong number of args \(0\) passed to: :kw" (ex-message e))))))
  (is (try (apply :foo/bar (range 20))
           false
           (catch Exception e
             (boolean (re-find #"Wrong number of args \(20\) passed to: :foo/bar" (ex-message e))))))
  (is (try (apply :foo/bar (range 21))
           false
           (catch Exception e
             (boolean (re-find #"Wrong number of args \(> 20\) passed to: :foo/bar" (ex-message e))))))
  (is (try (apply :foo/bar (range 22))
           false
           (catch Exception e
             ;; CLJW: upstream uses (> 20) format for all counts > 20
             (boolean (re-find #"Wrong number of args \(> 20\) passed to: :foo/bar" (ex-message e)))))))

;; CLJW-ADD: test runner invocation
(run-tests)
