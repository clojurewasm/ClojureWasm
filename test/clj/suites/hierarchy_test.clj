;; Ad-hoc hierarchies: make-hierarchy / derive / underive / isa? / parents /
;; ancestors / descendants over the global (atom-backed) hierarchy, plus the
;; defmulti dispatch that consults it (D-161).
;;
;; DIVERGENCE: cljw has no JVM Class, so the class? branches of clojure.core's
;; isa? / parents / ancestors are dropped (keyword, symbol and vector tags
;; only); derive is lenient about namespacing.
;;
;; Migrated from test/e2e/phase14_hierarchy.sh (24 `cljw -e` spawns). That
;; file's header noted "Each `cljw -e` is a fresh process, so the global
;; hierarchy resets per case", which is a dependence on the PROCESS for STATE
;; rather than for assertions. The suite shares ONE image, so every test here
;; uses tags unique to itself. That is the isolation, made explicit instead of
;; inherited: a shared tag would let one test's `derive` decide another test's
;; `isa?`, and the failure would then depend on declaration order.
(ns suites.hierarchy-test
  (:require [clojure.test :refer [deftest is]]))

;; --- isa? base cases, no hierarchy involved ---

(deftest isa-equality
  (is (true? (isa? 5 5)))
  (is (false? (isa? 5 6))))

(deftest make-hierarchy-is-empty
  (is (= {:parents {} :descendants {} :ancestors {}} (make-hierarchy))))

;; --- derive + isa?, direct and transitive ---

(deftest derive-direct
  (derive ::d1-child ::d1-parent)
  (is (true? (isa? ::d1-child ::d1-parent))))

(deftest derive-transitive
  (derive ::d2-dog ::d2-animal)
  (derive ::d2-animal ::d2-thing)
  (is (true? (isa? ::d2-dog ::d2-thing))))

(deftest unrelated-tags-are-not-isa
  (is (false? (isa? ::d3-cat ::d3-dog))))

;; --- queries ---

(deftest parents-of-a-derived-tag
  (derive ::q1-child ::q1-parent)
  (is (= #{::q1-parent} (parents ::q1-child))))

(deftest ancestors-walks-transitively
  (derive ::q2-dog ::q2-animal)
  (derive ::q2-animal ::q2-thing)
  (is (= #{::q2-animal ::q2-thing} (ancestors ::q2-dog))))

(deftest descendants-inverts-derive
  (derive ::q3-dog ::q3-animal)
  (is (= #{::q3-dog} (descendants ::q3-animal))))

(deftest ancestors-of-an-unrelated-tag-is-nil
  (is (nil? (ancestors ::q4-loner))))

;; --- vector isa? is elementwise ---

(deftest isa-vector-elementwise
  (derive ::v1-dog ::v1-animal)
  (is (true? (isa? [::v1-dog ::v1-dog] [::v1-animal ::v1-animal])))
  (is (false? (isa? [::v1-dog ::v1-cat] [::v1-animal ::v1-animal]))))

;; --- underive removes one relationship and keeps the others ---

(deftest underive-removes-the-relationship
  (derive ::u1-a ::u1-b)
  (underive ::u1-a ::u1-b)
  (is (false? (isa? ::u1-a ::u1-b))))

(deftest underive-keeps-unrelated-parents
  (derive ::u2-a ::u2-b)
  (derive ::u2-a ::u2-c)
  (underive ::u2-a ::u2-b)
  (is (= [false true] [(isa? ::u2-a ::u2-b) (isa? ::u2-a ::u2-c)])))

;; --- defmulti dispatch consults the global hierarchy via isa? (D-161).
;; The macro threads -global-hierarchy into the MultiFn, so a `derive` issued
;; even AFTER the defmulti is seen, and the method cache invalidates on the
;; hierarchy snapshot's identity. Each multimethod is uniquely named for the
;; same reason the tags are. ---

(defmulti mm1-area :shape)
(defmethod mm1-area ::m1-rect [r] :rect-fn)

(deftest multimethod-dispatch-through-derive
  (derive ::m1-square ::m1-rect)
  (is (= :rect-fn (mm1-area {:shape ::m1-square}))))

(defmulti mm2-area :shape)
(defmethod mm2-area ::m2-rect [r] :rect-fn)
(defmethod mm2-area :default [r] :def-fn)

;; The first call populates the method cache with the :default answer; the
;; derive must invalidate it.
(deftest multimethod-cache-invalidates-on-derive
  (is (= :def-fn (mm2-area {:shape ::m2-square})))
  (derive ::m2-square ::m2-rect)
  (is (= :rect-fn (mm2-area {:shape ::m2-square}))))

(defmulti mm3-area :shape)
(defmethod mm3-area ::m3-s3 [r] :s3-fn)

(deftest multimethod-dispatch-is-transitive
  (derive ::m3-square ::m3-rect)
  (derive ::m3-rect ::m3-s3)
  (is (= :s3-fn (mm3-area {:shape ::m3-square}))))

(defmulti mm4-area :shape)
(defmethod mm4-area ::m4-rect [r] :rect-fn)
(defmethod mm4-area :default [r] :def-fn)

(deftest multimethod-falls-back-to-default
  (is (= :def-fn (mm4-area {:shape ::m4-tri}))))

(defmulti mm5-area :shape)
(defmethod mm5-area ::m5-rect [r] :r)
(defmethod mm5-area ::m5-round [r] :ro)

(deftest multimethod-prefer-method-breaks-the-tie
  (derive ::m5-square ::m5-rect)
  (derive ::m5-square ::m5-round)
  (prefer-method mm5-area ::m5-rect ::m5-round)
  (is (= :r (mm5-area {:shape ::m5-square}))))

;; --- malformed hierarchy ops throw, matching clj (g5 HIER-GUARDS). These
;; used to silently return a value. clj raises UnsupportedOperationException /
;; AssertionError / NPE respectively; cljw matches by THROWING, and the
;; exception-Kind difference is the accepted divergence AD-007, so `thrown?`
;; on Throwable is the right granularity here. ---

(deftest descendants-of-a-class-throws
  (is (thrown? Throwable (descendants (class 5)))))

(deftest self-derive-throws
  (is (thrown? Throwable (derive ::g1-x ::g1-x))))

(deftest derive-with-nil-hierarchy-throws
  (is (thrown? Throwable (derive nil ::g2-a ::g2-b))))

(deftest derive-with-non-hierarchy-map-throws
  (is (thrown? Throwable (derive {} ::g3-a ::g3-b))))

(deftest underive-with-non-hierarchy-map-throws
  (is (thrown? Throwable (underive {} ::g4-a ::g4-b))))
