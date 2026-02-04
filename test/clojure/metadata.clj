;; Ported from clojure/test_clojure/metadata.clj
;; Tests for meta, with-meta, vary-meta
;;
;; SKIP: public-vars-with-docstrings-have-added (ns-publics not implemented)
;; SKIP: interaction-of-def-with-metadata (eval-in-temp-ns JVM-specific)
;; SKIP: fns-preserve-metadata-on-maps/vectors/sets (metadata preservation
;;       across assoc/dissoc/reduce/etc not yet implemented)
;; SKIP: defn-primitive-args (eval-in-temp-ns JVM-specific)

(ns test.metadata
  (:use clojure.test))

;; --- with-meta / meta basics ---

(deftest t-with-meta-map
  (let [m (with-meta {:a 1} {:tag "test"})]
    (is (= {:tag "test"} (meta m)))
    (is (= {:a 1} m))))

(deftest t-with-meta-vector
  (let [v (with-meta [1 2 3] {:x 1})]
    (is (= {:x 1} (meta v)))
    (is (= [1 2 3] v))))

(deftest t-with-meta-set
  (let [s (with-meta #{1 2 3} {:y 2})]
    (is (= {:y 2} (meta s)))))

(deftest t-with-meta-list
  (let [l (with-meta '(1 2 3) {:z 3})]
    (is (= {:z 3} (meta l)))))

(deftest t-with-meta-replaces
  (let [m (with-meta {:a 1} {:x 1})
        m2 (with-meta m {:y 2})]
    (is (= {:y 2} (meta m2)))
    (is (nil? (:x (meta m2))))))

;; --- meta on values without metadata ---

(deftest t-meta-nil-for-plain-values
  (is (nil? (meta {})))
  (is (nil? (meta [])))
  (is (nil? (meta #{})))
  (is (nil? (meta nil)))
  (is (nil? (meta 42)))
  (is (nil? (meta "foo")))
  (is (nil? (meta :kw))))

;; --- vary-meta ---

(deftest t-vary-meta
  (let [m (with-meta {:a 1} {:x 1})]
    (is (= {:x 1 :y 2} (meta (vary-meta m assoc :y 2))))
    (is (= {:x 1} (meta m)))))  ;; original unchanged

(deftest t-vary-meta-dissoc
  (let [m (with-meta {:a 1} {:x 1 :y 2})]
    (is (= {:x 1} (meta (vary-meta m dissoc :y))))))

;; --- nested metadata ---

(deftest t-nested-metadata
  (let [inner (with-meta {:foo 1} {:inner true})
        outer (with-meta {:bar inner} {:outer true})]
    (is (= {:outer true} (meta outer)))
    (is (= {:inner true} (meta (:bar outer))))))

;; --- with-meta nil metadata ---

(deftest t-with-meta-nil
  (let [m (with-meta {:a 1} nil)]
    (is (nil? (meta m)))))

(run-tests)
