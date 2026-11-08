;; D-089 dispatch contracts. Isolated process: native-tag extension is global.
;; The shell shim owns launch/build only; value assertions run in cljw.
(ns process.seq-protocol-extensions)

(defrecord FirstBox [v])
(extend-type FirstBox ISeq (-first [b] (get b :v)))
(assert (= 42 (first (->FirstBox 42))) "record first override")

(defrecord RestBox [v])
(extend-type RestBox ISeq (-rest [_] '(99)))
(assert (= '(99) (rest (->RestBox 42))) "record rest override")

(defrecord NextBox [v])
(extend-type NextBox ISeq (-next [b] (get b :v)))
(assert (= "hi" (next (->NextBox "hi"))) "record next override")

(defrecord EmptyBox [v])
(extend-type EmptyBox IPersistentCollection (-empty [_] :empty-box))
(assert (= :empty-box (empty (->EmptyBox 42))) "record empty override")

(def NativeLong (cljw.internal/__native-type :integer))
(extend-type NativeLong ISeq
  (-first [n] (+ n 100))
  (-rest [n] (list (dec n)))
  (-next [n] (when (pos? n) (list (dec n)))))
(assert (= 142 (first 42)) "native-tag first override")
(assert (= '(41) (rest 42)) "native-tag rest override")
(assert (= '(41) (next 42)) "native-tag next override")
(assert (nil? (next 0)) "native-tag exhausted next")

(assert (= '(2 3) (next [1 2 3])) "vector next")
(assert (nil? (next [1])) "singleton next")
(assert (nil? (next nil)) "nil next")
(println "PASS seq_protocol_extensions: 11 assertions")
