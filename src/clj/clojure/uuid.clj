;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/src/clj/clojure/uuid.clj
;; Upstream lines: 21
;; CLJW markers: 2

(ns clojure.uuid)

;; CLJW: java.util.UUID/fromString → __uuid-from-string (CW internal builtin)
(defn- default-uuid-reader [form]
  (if (string? form)
    (__uuid-from-string form)
    (throw (ex-info "#uuid data reader expected string" {:form form}))))

;; CLJW: print-method/print-dup not needed — CW handles UUID printing in Zig (value.zig)
