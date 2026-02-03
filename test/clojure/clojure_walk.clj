;; Tests for clojure.walk namespace
;; Ported from upstream test/clojure/test_clojure/clojure_walk.clj
;;
;; PARTIAL: 5/8 tests ported
;; SKIP: t-stringify-keys (needs stringify-keys impl)
;; SKIP: walk-mapentry (needs map-entry? predicate)
;; SKIP: retain-meta (walk doesn't preserve metadata - D54)
;;
;; NOTE: t-prewalk-order and t-postwalk-order use let+closure which triggers
;; F75 (VM closure capture with named fn self-ref). These tests pass on TreeWalk.
;; Run with: ./zig-out/bin/cljw --tree-walk test/clojure/clojure_walk.clj

(deftest t-prewalk-replace
  (testing "prewalk-replace substitutes at root first"
    (is (= (prewalk-replace {:a :b} [:a {:a :a} (list 3 :c :a)])
           [:b {:b :b} (list 3 :c :b)]))))

(deftest t-postwalk-replace
  (testing "postwalk-replace substitutes at leaves first"
    (is (= (postwalk-replace {:a :b} [:a {:a :a} (list 3 :c :a)])
           [:b {:b :b} (list 3 :c :b)]))))

(deftest t-prewalk-order
  (testing "prewalk visits nodes in pre-order (parent before children)"
    (is (= (let [a (atom [])]
             (prewalk (fn [form] (swap! a conj form) form)
                      [1 2 {:a 3} (list 4 [5])])
             @a)
           [[1 2 {:a 3} (list 4 [5])]
            1 2 {:a 3} [:a 3] :a 3 (list 4 [5])
            4 [5] 5]))))

(deftest t-postwalk-order
  (testing "postwalk visits nodes in post-order (children before parent)"
    (is (= (let [a (atom [])]
             (postwalk (fn [form] (swap! a conj form) form)
                       [1 2 {:a 3} (list 4 [5])])
             @a)
           [1 2
            :a 3 [:a 3] {:a 3}
            4 5 [5] (list 4 [5])
            [1 2 {:a 3} (list 4 [5])]]))))

(deftest t-walk-collections
  (testing "walk returns correct result for different collection types"
    ;; List
    (is (= (walk identity identity '(1 2 3)) '(1 2 3)))
    (is (= (walk inc #(reduce + %) '(1 2 3)) 9))  ; (2+3+4)

    ;; Vector
    (is (= (walk identity identity [1 2 3]) [1 2 3]))
    (is (= (walk inc #(reduce + %) [1 2 3]) 9))

    ;; Set
    (is (= (walk identity identity #{1 2 3}) #{1 2 3}))
    (is (= (walk inc #(reduce + %) #{1 2 3}) 9))

    ;; Map
    (is (= (walk identity identity {:a 1 :b 2 :c 3}) {:a 1 :b 2 :c 3}))
    ;; Map walk applies inner to [k v] entries
    ;; SKIP: upstream uses update-in which requires assoc-in (not yet implemented)
    ;; Original: (is (= (w/walk #(update-in % [1] inc) #(reduce + (vals %)) c)
    ;;                  (reduce + (map (comp inc val) c))))
    ))

(run-tests)
