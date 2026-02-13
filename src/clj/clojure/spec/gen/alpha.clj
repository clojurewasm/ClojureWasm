;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; CLJW: Stub namespace — gen functions throw until test.check is available.
;; Full implementation deferred to Phase 70.4.

(ns clojure.spec.gen.alpha
  (:refer-clojure :exclude [boolean bytes cat delay hash-map list map not-empty set shuffle vector]))

;; CLJW: Stub gen functions that spec.alpha references.
;; All throw at call time since test.check is not available.

(defn- stub-fn [name]
  (fn [& _]
    (throw (ex-info (str "clojure.spec.gen.alpha/" name " requires test.check (not available)")
                    {:fn name}))))

(def such-that (stub-fn "such-that"))
(def return (stub-fn "return"))
(def bind (stub-fn "bind"))
(def tuple (stub-fn "tuple"))
(def choose (stub-fn "choose"))
(def shuffle (stub-fn "shuffle"))
(def fmap (stub-fn "fmap"))
(def hash-map (stub-fn "hash-map"))
(def one-of (stub-fn "one-of"))
(def cat (stub-fn "cat"))
(def vector (stub-fn "vector"))
(def vector-distinct (stub-fn "vector-distinct"))
(def gen-for-pred (stub-fn "gen-for-pred"))
(def frequency (stub-fn "frequency"))
(def sample (stub-fn "sample"))
(def generate (stub-fn "generate"))
(def delay (stub-fn "delay"))
(def quick-check (stub-fn "quick-check"))
(def for-all* (stub-fn "for-all*"))
(def large-integer* (stub-fn "large-integer*"))
(def double* (stub-fn "double*"))
(def not-empty (stub-fn "not-empty"))
(def boolean (stub-fn "boolean"))
(def list (stub-fn "list"))
(def map (stub-fn "map"))
(def set (stub-fn "set"))
(def bytes (stub-fn "bytes"))
