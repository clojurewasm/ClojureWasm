(ns demo.math-test
  (:require [clojure.test :refer [deftest is are testing run-tests]]
            [demo.math :as m]))
(deftest squares
  (is (= 9 (m/square 3)))
  (is (= 27 (m/cube 3)))
  (testing "are over a table"
    (are [n sq] (= sq (m/square n)) 2 4 5 25)))
