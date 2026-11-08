;; Truthiness, equality and hashing — the semantics everything else rests on.
;; Only nil and false are falsey; 0 and "" are truthy, unlike most languages.
(prn (mapv boolean [nil false 0 "" [] {} :k]))
(prn (= 1 1.0) (== 1 1.0) (identical? :a :a) (identical? [1] [1]))
(prn (= [1 2] '(1 2)) (= #{1 2} #{2 1}) (= {:a 1} {:a 1}) (= "a" \a))
;; Equal values must hash equal, or every map and set built from them is wrong.
(prn (= (hash [1 2]) (hash [1 2])) (= (hash {:a 1}) (hash {:a 1})) (= (hash #{1 2}) (hash #{2 1})))
(prn (mapv nil? [nil false]) (mapv some? [nil 0]) (mapv seq? ['(1) [1]]))
(prn (compare 1 2) (compare "b" "a") (compare [1 2] [1 3]) (compare nil nil))
