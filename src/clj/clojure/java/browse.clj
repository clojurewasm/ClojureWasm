;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/src/clj/clojure/java/browse.clj
;; Upstream lines: 89
;; CLJW markers: 4

(ns
 ^{:author "Christophe Grand",
   :doc "Start a web browser from Clojure"}
 clojure.java.browse
  (:require [clojure.java.shell :as sh]
            [clojure.string :as str]))
;; CLJW: removed (:import) — no File, URI, ProcessBuilder needed

(defn- macosx? []
  ;; CLJW: System/getProperty → CW builtin
  (-> (System/getProperty "os.name") .toLowerCase
      (.startsWith "mac os x")))

(defn- xdg-open-loc []
  ;; try/catch needed to mask exception on Windows without Cygwin
  (let [which-out (try (:out (sh/sh "which" "xdg-open"))
                       (catch Exception e ""))]
    (if (= which-out "")
      nil
      (str/trim-newline which-out))))

(defn- open-url-script-val []
  (if (macosx?)
    "/usr/bin/open"
    (xdg-open-loc)))

(def ^:dynamic *open-url-script* (atom :uninitialized))

;; CLJW: open-url-in-browser (AWT Desktop) and open-url-in-swing skipped — no GUI

(defn browse-url
  "Open url in a browser"
  {:added "1.2"}
  [url]
  ;; CLJW: simplified — uses sh/sh instead of ProcessBuilder, no AWT/Swing fallback
  (let [script @*open-url-script*
        script (if (= :uninitialized script)
                 (reset! *open-url-script* (open-url-script-val))
                 script)]
    (when script
      (sh/sh script (str url))
      url)))
