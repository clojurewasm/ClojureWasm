;; clojure.data.csv — CSV read/write (RFC 4180). cw v1 §9.11 row 9.4.
;;
;; The Layer-2 primitives `read-csv` + `write-csv` are interned by
;; `src/lang/primitive/csv.zig::register`. cw v1 deviates from JVM
;; on signatures: `read-csv` takes a string (not a Reader); `write-csv`
;; takes data + returns a string (not data + Writer + returns nil).
;; Reader/Writer stream APIs land alongside Phase 14+ IO abstractions.
(ns clojure.data.csv
  (:refer-clojure))
