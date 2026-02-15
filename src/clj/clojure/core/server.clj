;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/src/clj/clojure/core/server.clj
;; Upstream lines: 341
;; CLJW markers: 3

;; CLJW: Stub namespace. Socket server requires Zig networking infrastructure
;; not yet implemented. Provides API surface for library compatibility.

(ns ^{:doc "Socket server support"
      :author "Alex Miller"}
 clojure.core.server
  (:require [clojure.string :as str]
            [clojure.edn :as edn]
            [clojure.main :as m]))

;; CLJW: no Java imports, ServerSocket, Thread, ReentrantLock

(def ^:dynamic *session* nil)

(defn start-server
  "Start a socket server. Not yet implemented in CW."
  ;; CLJW: stub — requires Zig socket server infrastructure
  [opts]
  (throw (ex-info "clojure.core.server/start-server not yet implemented in CW" {:opts opts})))

(defn stop-server
  "Stop server with name or all if no name."
  ([] nil)
  ([name] nil))

(defn stop-servers
  "Stop all servers."
  []
  nil)

(defn prepl
  "A REPL with structured output. Not yet implemented in CW."
  [in-reader out-fn & {:keys [stdin]}]
  (throw (ex-info "clojure.core.server/prepl not yet implemented in CW" {})))

(defn io-prepl
  "prepl bound to *in* and *out*, suitable for use with start-server"
  []
  (throw (ex-info "clojure.core.server/io-prepl not yet implemented in CW" {})))

(defn remote-prepl
  "Implements a prepl on in-reader and out-fn by forwarding to a
  remote [host port] prepl over a socket."
  [host port in-reader out-fn & {:keys [valf] :or {valf read-string}}]
  (throw (ex-info "clojure.core.server/remote-prepl not yet implemented in CW" {})))
