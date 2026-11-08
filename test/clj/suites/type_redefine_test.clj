;; D-587: redefining a deftype/defrecord name must not invalidate instances
;; that were constructed against the previous definition.
;;
;; clj's semantics: re-evaluating `defrecord` creates a NEW class. Instances
;; made earlier keep the OLD class and keep printing, reading and comparing
;; correctly; the old class becomes garbage only when nothing references it.
;; cljw used to FREE the old TypeDescriptor on re-registration while live
;; instances still held a raw pointer to it, so touching an older instance
;; read freed memory. The symptom varied with whatever the freed memory
;; happened to contain: `thread panic: integer overflow` on some shapes,
;; `WriteFailed` on others, which is itself the signature of a
;; use-after-free rather than a logic error.
;;
;; This is a native suite rather than a shell e2e even though the OLD symptom
;; was a process abort: a crash cannot be caught in-process, but the FIXED
;; behaviour is an ordinary value assertion, which is where it belongs. The
;; consequence is that this file and the fix must land together, since the
;; suite runner shares one image and a crash here takes every suite with it.
(ns suites.type-redefine-test
  (:require [clojure.test :refer [deftest is]]))

;; --- two namespaces defining the SAME simple name must retain distinct
;; descriptors. Unlike re-evaluation, this is not a redefine: the registry
;; key must include the namespace. The CLI reproduction is the
;; `ns-collision-then-narrowing-redefine` row at the end of this file.
(ns suites.tduafa)
(defrecord Point [x y])
(def a (->Point 1 2))

(ns suites.tduafb)
(defrecord Point [x y])
(def b (->Point 3 4))

(ns suites.type-redefine-test
  (:require [clojure.test :refer [deftest is]]))

(deftest equal-simple-names-in-distinct-namespaces
  (is (= "#suites.tduafa.Point{:x 1, :y 2}" (pr-str suites.tduafa/a)))
  (is (= "#suites.tduafb.Point{:x 3, :y 4}" (pr-str suites.tduafb/b)))
  (is (not (= (class suites.tduafa/a) (class suites.tduafb/b)))))

;; --- same name, same shape, redefined in one namespace (the REPL re-eval
;; and `require :reload` path) ---

(defrecord RedefSameShape [x y])

(def ^:private same-shape-before (->RedefSameShape 1 2))
(def ^:private same-shape-repr-at-construction (pr-str same-shape-before))

(defrecord RedefSameShape [x y])

(def ^:private same-shape-after (->RedefSameShape 1 2))

(deftest older-instance-survives-a-same-shape-redefine
  (is (= same-shape-repr-at-construction (pr-str same-shape-before))))

(deftest older-instance-keeps-its-fields-after-redefine
  (is (= [1 2] [(:x same-shape-before) (:y same-shape-before)])))

(deftest newer-instance-works-after-redefine
  (is (= [1 2] [(:x same-shape-after) (:y same-shape-after)])))

;; --- same name, DIFFERENT field count: the retired layout must not be
;; consulted for the new type, nor the new layout for the old instance ---

(defrecord RedefDifferentShape [a b])

(def ^:private two-field (->RedefDifferentShape 7 8))
(def ^:private two-field-repr-at-construction (pr-str two-field))

(defrecord RedefDifferentShape [a])

(def ^:private one-field (->RedefDifferentShape 9))

(deftest older-instance-survives-a-narrowing-redefine
  (is (= two-field-repr-at-construction (pr-str two-field))))

(deftest older-instance-keeps-both-fields-after-narrowing
  (is (= [7 8] [(:a two-field) (:b two-field)])))

(deftest newer-narrower-instance-is-correct
  (is (= 9 (:a one-field)))
  (is (nil? (:b one-field))))

;; --- a deftype redefine, which failed with a different symptom (WriteFailed)
;; but the same root cause ---

(deftype RedefType [p q])

(def ^:private typed-before (RedefType. 3 4))

(deftype RedefType [p q])

(deftest older-deftype-instance-survives-redefine
  (is (= [3 4] [(.-p typed-before) (.-q typed-before)])))

;; --- equality and hashing must not read the retired layout either ---

(defrecord RedefEquality [v])

(def ^:private eq-before (->RedefEquality 5))

(defrecord RedefEquality [v])

(def ^:private eq-after (->RedefEquality 5))

;; What this row guarantees is that asking the question does not crash and
;; that each instance still equals one of its own vintage. Whether an old and
;; a new instance compare equal is a separate question (clj says no, they are
;; different classes); it is pinned loosely here on purpose so this test
;; fails for a use-after-free and not for a defensible answer either way.
(deftest redefined-type-equality-is-well-defined
  (is (= eq-before eq-before))
  (is (= eq-after eq-after))
  (is (boolean? (= eq-before eq-after))))

(deftest redefined-type-hash-is-well-defined
  (is (integer? (hash eq-before)))
  (is (integer? (hash eq-after))))

;; --- a class VALUE captured before the redefine stays traceable ---
;; `makeTypeDescriptorRef` hands out a process-lifetime boxed ref that the GC
;; traces as a persistent mark waypoint via `markDescriptorValues`. Freeing
;; the descriptor left that waypoint pointing at freed memory, so the
;; use-after-free could also fire inside the MARK phase rather than at print
;; time. Holding the ref across a redefine and then forcing a collect is the
;; assertion for that path.
(defrecord RedefClassRef [n])

(def ^:private captured-class (class (->RedefClassRef 1)))

(defrecord RedefClassRef [n])

(deftest captured-class-value-survives-redefine-and-collect
  (dotimes [_ 200] (vec (range 64)))
  (is (some? captured-class))
  (is (string? (pr-str captured-class))))

;; --- scenarios migrated from the former test/e2e/type_descriptor_redefinition.sh.
;; Every expected value is the JVM's (clojure -M). The printed forms use
;; hyphen-free namespaces because clj munges `-` to `_` in a record class name
;; and cljw does not yet (ADR-0201 Consequences). ---

;; Same simple name in two namespaces, then a narrowing redefine in the first.
(ns suites.tdra)
(defrecord Point [x y])
(def a (->Point 1 2))

(ns suites.tdrb)
(defrecord Point [x y])
(def b (->Point 3 4))

(ns suites.tdra)
(def a-repr-after-namesake (pr-str a))
(defrecord Point [x])
(def a-after (->Point 5))
(deftype Box [v])
(def old-box (Box. 7))
(deftype Box [v])

;; defrecord R [a] -> R [a b], each vintage extended separately; a deftype
;; with an inline impl redefined without it; then registration churn under GC.
(ns suites.tdrc)
(defprotocol Area (area [s]))
(defrecord R [a])
(extend-protocol Area R (area [s] (:a s)))
(def r (->R 1))
(def rc (class r))
(defrecord R [a b])
(extend-protocol Area R (area [s] (+ (:a s) (:b s))))
(def r-new (->R 2 3))
(def r-nil (->R 1 nil))

(deftype T [x] Area (area [_] x))
(def t (T. 5))
(deftype T [x y])

(def last-area (atom nil))
(dotimes [i 3000]
  (eval '(defrecord Churn [v]))
  (reset! last-area (area (reify Area (area [_] i)))))
(def cs (vec (for [i (range 50)]
               (do (eval '(defrecord Churn [v w]))
                   ((ns-resolve 'suites.tdrc '->Churn) i i)))))
(System/gc)

;; A constructor form binds the class of the namespace it was WRITTEN in
;; ([CLJW-CTOR-ANALYZE-TIME]). The factories, a `(Point. x y)` in a later fn
;; and one inside the record's own method body all build suites.tdrd.Point when
;; called from another namespace after suites.tdre registered a namesake with a
;; different shape.
(ns suites.tdrd)
(defprotocol Grow (grow [p]))
(defrecord Point [x y] Grow (grow [_] (Point. (inc x) y)))
(deftype Box [v])
(defn mk [] (Point. 1 2))

(ns suites.tdre)
(defrecord Point [q])
(deftype Box [v w])

(ns suites.type-redefine-test
  (:require [clojure.test :refer [deftest is]]))

(deftest ns-collision-then-narrowing-redefine
  (is (= "#suites.tdra.Point{:x 1, :y 2}" (pr-str suites.tdra/a)))
  (is (= "#suites.tdra.Point{:x 1, :y 2}" suites.tdra/a-repr-after-namesake))
  (is (= "#suites.tdrb.Point{:x 3, :y 4}" (pr-str suites.tdrb/b)))
  (is (= "#suites.tdra.Point{:x 5}" (pr-str suites.tdra/a-after)))
  (is (= 7 (.-v suites.tdra/old-box))))

(deftest widening-redefine-keeps-the-old-vintage-whole
  (let [r suites.tdrc/r rc suites.tdrc/rc]
    (is (= "#suites.tdrc.R{:a 1}" (pr-str r)))
    (is (= 1 (:a r)))
    (is (= 1 (.-a r)))
    (is (true? (instance? rc r)))
    (is (true? (= rc (class r))))
    (is (false? (= (class r) suites.tdrc.R)))
    (is (true? (= r r)))
    (is (false? (= r suites.tdrc/r-nil)))
    (is (= (hash r) (hash r)))
    (is (true? (map? r)))
    (is (= 1 (suites.tdrc/area r)))
    (is (= 5 (suites.tdrc/area suites.tdrc/r-new)))))

(deftest deftype-redefine-keeps-the-old-method-table
  (let [t suites.tdrc/t]
    (is (= 5 (.-x t)))
    (is (= 5 (suites.tdrc/area t)))
    (is (= t t))
    (is (integer? (hash t)))))

(deftest redefine-churn-under-gc
  (let [cs suites.tdrc/cs]
    (is (= 1225 (reduce + (map :v cs))))
    (is (= "#suites.tdrc.Churn{:v 0, :w 0}" (pr-str (first cs))))
    (is (= "#suites.tdrc.Churn{:v 49, :w 49}" (pr-str (last cs))))
    (is (= 2999 @suites.tdrc/last-area))))

(deftest ctor-binds-its-defining-namespace
  (is (= "#suites.tdrd.Point{:x 1, :y 2}" (pr-str (suites.tdrd/->Point 1 2))))
  (is (= "#suites.tdrd.Point{:x 1, :y 2}" (pr-str (suites.tdrd/mk))))
  (is (= "#suites.tdrd.Point{:x 2, :y 2}" (pr-str (suites.tdrd/grow (suites.tdrd/->Point 1 2)))))
  (is (= "#suites.tdre.Point{:q 9}" (pr-str (suites.tdre/->Point 9))))
  (is (= "#suites.tdrd.Point{:x 1, :y 2}" (pr-str (suites.tdrd/map->Point {:x 1 :y 2}))))
  (is (true? (instance? suites.tdrd.Point (suites.tdrd/mk))))
  (is (false? (instance? suites.tdre.Point (suites.tdrd/mk))))
  (is (= 7 (.-v (suites.tdrd/->Box 7))))
  (is (= 8 (.-w (suites.tdre/->Box 7 8)))))
