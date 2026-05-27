;; clojure.data.json — JSON read/write. cw v1 §9.11 row 9.3 landing.
;;
;; Surface mirrors JVM clojure.data.json 2.5.x: `read-str` parses a
;; JSON string into a cw value (vector / array_map / string / number
;; / nil / bool); `write-str` serialises a cw value into a JSON
;; string. The Layer-2 primitives are interned by
;; `src/lang/primitive/json.zig::register`; this file's only job is
;; to open the namespace so user `(require '[clojure.data.json :as
;; json])` finds it.
(ns clojure.data.json
  (:refer-clojure))
