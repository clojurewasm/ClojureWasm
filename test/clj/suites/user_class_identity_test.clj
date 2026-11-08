;; ADR-0201: a user-defined class (deftype / defrecord / reify) IS its
;; TypeDescriptor, so membership in it is decided by descriptor identity,
;; never by comparing simple-name strings.
;;
;; The simple-name oracle survived ADR-0198 (which gave every other question,
;; `(class x)`, `=` on classes, printing, the registry key, a per-descriptor
;; answer) and so answered `instance?` and `isa?` differently from `=`:
;; after `(defrecord R [a b])` replaced `(defrecord R [a])`, an OLD instance
;; was still `(instance? R old)`, a record from another namespace with the same
;; simple name was an instance of this one, and a deftype named `Sorted` was
;; `sorted?`. Every expected value below is the JVM's (`clojure -M`).
(ns suites.user-class-identity-test
  (:require [clojure.test :refer [deftest is testing]]))

(defprotocol Area (area [s]))

;; --- same-namespace redefinition: the new class is a DIFFERENT class ---

(defrecord R [a])
(def ^:private old-r (->R 1))
(def ^:private old-r-class (class old-r))
(defrecord R [a b])
(def ^:private new-r (->R 1 2))

(deftest instance-of-redefined-record
  (is (false? (instance? R old-r)))
  (is (true? (instance? old-r-class old-r)))
  (is (true? (instance? R new-r)))
  (is (false? (instance? old-r-class new-r))))

(deftest class-isInstance-agrees-with-instance?
  (is (false? (.isInstance R old-r)))
  (is (true? (.isInstance old-r-class old-r))))

(deftest isa?-between-record-vintages
  (is (false? (isa? old-r-class R)))
  (is (false? (isa? R old-r-class)))
  (is (true? (isa? old-r-class old-r-class)))
  (is (true? (isa? R R)))
  (testing "a user class still sits under Object"
    (is (true? (isa? old-r-class Object)))
    (is (true? (instance? Object old-r)))))

(defmulti ^:private by-class class)
(defmethod by-class :default [_] :default)
(defmethod by-class R [_] :new-r)

(defmulti ^:private by-old-class class)
(defmethod by-old-class old-r-class [_] :old-r)
(defmethod by-old-class :default [_] :default)

(deftest multimethod-dispatch-on-class-vintage
  (testing "a method keyed by the NEW class does not catch an old instance"
    (is (= :default (by-class old-r)))
    (is (= :new-r (by-class new-r))))
  (testing "a method keyed by the OLD class catches only the old instance"
    (is (= :old-r (by-old-class old-r)))
    (is (= :default (by-old-class new-r)))))

(deftype T [x])
(def ^:private old-t (T. 1))
(def ^:private old-t-class (class old-t))
(deftype T [x])

(deftest instance-of-redefined-deftype
  (is (false? (instance? T old-t)))
  (is (true? (instance? old-t-class old-t)))
  (is (true? (instance? T (T. 2))))
  (is (false? (= old-t-class T))))

;; --- reify: its class value is a class like any other ---

(defn- mk-area [i] (reify Area (area [_] i)))

(deftest reify-instance-of-its-own-class
  (let [a (mk-area 1)]
    (is (true? (instance? (class a) a)))
    (is (true? (.isInstance (class a) a)))
    (is (true? (isa? (class a) (class a))))
    (is (true? (instance? Object a)))
    (is (= 1 (area a)))))

;; --- a user type named like a host interface is not that interface ---

(deftype Sorted [])

(deftest user-type-named-like-an-interface
  (is (false? (sorted? (Sorted.))))
  (is (true? (instance? Sorted (Sorted.))))
  (is (false? (instance? clojure.lang.Sorted (Sorted.)))))

;; --- class-level isa? of a user class against a host class: what the user
;; class DECLARES decides, never its simple name. These names are each a host
;; class's simple name, which the name oracle used to match. ---

(deftype BigInt [])
(deftype Keyword [])
(deftype PersistentVector [])
(deftype LazySeq [])
(deftype ExceptionInfo [])
(deftype Ratio [])
(deftype Deref [] clojure.lang.IDeref (deref [_] :derefed))

(deftest user-class-named-like-a-host-class-is-not-a-subclass-of-it
  (is (false? (isa? BigInt Number)))
  (is (false? (isa? Ratio Number)))
  (is (false? (isa? Keyword clojure.lang.IFn)))
  (is (false? (isa? PersistentVector clojure.lang.IFn)))
  (is (false? (isa? PersistentVector clojure.lang.IPersistentVector)))
  (is (false? (isa? LazySeq clojure.lang.Seqable)))
  (is (false? (isa? ExceptionInfo Exception)))
  (is (false? (isa? Sorted clojure.lang.Sorted)))
  (is (false? (number? (BigInt.))))
  (is (false? (ifn? (Keyword.))))
  (testing "Object and the declared interfaces still answer"
    (is (true? (isa? BigInt Object)))
    (is (true? (isa? Deref clojure.lang.IDeref)))
    (is (= :derefed @(Deref.)))))

(defmulti ^:private by-host-class class)
(defmethod by-host-class Number [_] :number)
(defmethod by-host-class clojure.lang.IFn [_] :ifn)
(defmethod by-host-class :default [_] :default)

(deftest multimethod-dispatch-on-a-user-class-named-like-a-host-class
  (is (= :default (by-host-class (BigInt.))))
  (is (= :default (by-host-class (Keyword.))))
  (is (= :number (by-host-class 1)))
  (is (= :ifn (by-host-class :k))))

;; --- two namespaces, one simple name: two classes ---

(ns suites.ucia)
(defrecord Point [x y])
(def a (->Point 1 2))

(ns suites.ucib)
(defrecord Point [q])
(def b (->Point 9))

(ns suites.user-class-identity-test)

(deftest same-simple-name-in-two-namespaces
  (is (false? (instance? suites.ucia.Point suites.ucib/b)))
  (is (true? (instance? suites.ucib.Point suites.ucib/b)))
  (is (true? (instance? suites.ucia.Point suites.ucia/a)))
  (is (false? (= (class suites.ucia/a) (class suites.ucib/b))))
  (is (false? (isa? (class suites.ucib/b) suites.ucia.Point)))
  ;; a factory builds ITS namespace's class, also when called from another
  ;; namespace after a namesake was registered later
  (is (= [5 6] ((juxt :x :y) (suites.ucia/->Point 5 6))))
  (is (true? (instance? suites.ucia.Point (suites.ucia/->Point 5 6))))
  (is (= {:x 7 :y 8} (into {} (suites.ucia/map->Point {:x 7 :y 8}))))
  (is (true? (instance? suites.ucib.Point (suites.ucib/->Point 1)))))

;; --- an INSTANCE dispatch value is not isa? its class's name, nor a protocol
;; its type declares: clj relates an instance only by equality or derive ---

(defmulti ^:private by-identity identity)
(defmethod by-identity 'R [_] :sym)
(defmethod by-identity :R [_] :kw)
(defmethod by-identity 'Area [_] :protocol)
(defmethod by-identity :default [_] :default)

(deftest instance-dispatch-value-is-not-its-class-name
  (is (= :default (by-identity new-r)))
  (is (= :default (by-identity (mk-area 1))))
  (is (false? (isa? new-r 'R)))
  (is (false? (isa? new-r :R))))
