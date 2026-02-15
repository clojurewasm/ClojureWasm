;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/src/clj/clojure/repl/deps.clj
;; Upstream lines: 97
;; CLJW markers: 2

;; CLJW: Stub namespace. Dynamic library loading requires CW deps.edn
;; resolver integration which is not yet stable.

(ns clojure.repl.deps
  "clojure.repl.deps provides facilities for dynamically modifying the available
  libraries in the runtime when running at the REPL, without restarting")

;; CLJW: no Java imports or tools.deps.interop

(defn add-libs
  "Given lib-coords, a map of lib to coord, will resolve all transitive deps for the libs
  together and add them to the repl classpath. Not yet implemented in CW."
  {:added "1.12"}
  [lib-coords]
  (throw (ex-info "clojure.repl.deps/add-libs not yet implemented in CW" {:libs lib-coords})))

(defn add-lib
  "Given a lib that is not yet on the repl classpath, make it available.
  Not yet implemented in CW."
  {:added "1.12"}
  ([lib coord]
   (add-libs {lib coord}))
  ([lib]
   (throw (ex-info "clojure.repl.deps/add-lib not yet implemented in CW" {:lib lib}))))

(defn sync-deps
  "Calls add-libs with any libs present in deps.edn but not yet present on the classpath.
  Not yet implemented in CW."
  {:added "1.12"}
  [& {:as opts}]
  (throw (ex-info "clojure.repl.deps/sync-deps not yet implemented in CW" {:opts opts})))
