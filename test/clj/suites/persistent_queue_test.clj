;; test/e2e/phase15_persistent_queue.sh — clojure.lang.PersistentQueue (ADR-0087).
;; The reader-round-trippable `#queue (…)` print form is the AD-012 pin (clj
;; prints an opaque non-reproducible #object). FIFO semantics + equality are
;; corpus-verified against clj (test/diff/clj_corpus/persistent_queue.txt); this
;; layer locks the cljw-specific print + reader round-trip. `cljw -e` echoes each
;; top-level form's value, so a bare queue value renders via its printValue. L2.

;; Migrated from test/e2e/phase15_persistent_queue.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.persistent-queue-test
  (:require [clojure.test :refer [deftest is]]))

(deftest persistent-queue-cases
  (is (= "#queue (1 2 3)" (pr-str (conj clojure.lang.PersistentQueue/EMPTY 1 2 3))) "print_nonempty")
  (is (= "#queue ()" (pr-str clojure.lang.PersistentQueue/EMPTY)) "print_empty")
  (is (= "#queue (1 2 3)" (pr-str (read-string "#queue (1 2 3)"))) "reader_rt")
  (is (= "true" (pr-str (queue? (read-string "#queue (1 2 3)")))) "reader_q")
  (is (= "true" (pr-str (= clojure.lang.PersistentQueue (class (conj clojure.lang.PersistentQueue/EMPTY 1))))) "class")
  (is (= "[true false false]" (pr-str [(queue? clojure.lang.PersistentQueue/EMPTY) (queue? [1]) (queue? nil)])) "queue_pred"))
