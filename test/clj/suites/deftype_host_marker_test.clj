;; D-275 / D-279..D-292: deftype/reify host-supertype markers and the
;; `clojure.lang.*` protocol_remap surface, asserted natively.
;;
;; Migrated from test/e2e/phase14_deftype_object.sh, which paid one cljw
;; process per case. What stayed in the shell is the part that needs the
;; PROCESS: an unwired host-marker method raises `feature_not_supported`,
;; whose Kind is `.not_implemented` and is DELIBERATELY uncatchable
;; (src/runtime/error/catalog.zig) so an unsupported feature cannot be
;; swallowed. A suite running inside cljw cannot observe that abort.
(ns suites.deftype-host-marker-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.core.protocols]))

;; --- Object/toString reaches the str/print path (D-275 slice 1) ---

(deftype ObjToStr [a]
  Object
  (toString [this] (str "F" a)))

(deftest reify-object-tostring
  (is (= "hello-obj" (str (reify Object (toString [this] "hello-obj"))))))

(deftest reify-empty-sections
  (is (some? (reify)))
  (is (some? (reify Object)))
  (is (= "x" (str (reify Object (toString [_] "x")))))
  (is (= {:m true} (meta (with-meta (reify Object) {:m true}))))
  (is (= {:m true}
         (binding [*data-readers* {'my/t (fn [_] (reify Object))}]
           (meta (read-string "^:m #my/t 1"))))))

(defprotocol EmptySectionProtocol (empty-section-method [this]))

(deftest reify-empty-protocol-section
  (is (some? (reify EmptySectionProtocol)))
  (is (= "x" (str (reify EmptySectionProtocol Object (toString [_] "x"))))))

(deftype EmptyObjectType [] Object)
(deftest deftype-empty-object-section
  (is (some? (EmptyObjectType.))))

(deftest deftype-object-tostring-field-reaches-body
  (is (= "F5" (str (ObjToStr. 5)))))

;; --- the cljw-protocol path is unregressed by the marker work ---

(defprotocol Doubler (dbl [x]))

(deftype ProtoDeftype [a]
  Doubler
  (dbl [this] (* a 2)))

(deftest protocol-deftype-unregressed
  (is (= 42 (dbl (ProtoDeftype. 21)))))

(deftest protocol-reify-unregressed
  (is (= 99 (dbl (reify Doubler (dbl [this] 99))))))

;; --- method arity overload, the priority-map valAt shape (D-279) ---

(deftype ArityLookup []
  ILookup
  (-lookup [this k] :two)
  (-lookup [this k nf] :three))

(deftest deftype-method-arity-overload
  (is (= [:two :three] [(get (ArityLookup.) :a) (.-lookup (ArityLookup.) :a :nf)])))

(deftest reify-method-arity-overload
  (let [r (reify ILookup
            (-lookup [this k] :two)
            (-lookup [this k nf] :three))]
    (is (= [:two :three] [(get r :a) (.-lookup r :a :nf)]))))

;; --- zero-method qualified markers parse and record (D-280a) ---

(deftype ZeroMethodMarkers [a]
  Object
  (toString [this] (str "T" a))
  clojure.lang.MapEquivalence
  java.io.Serializable)

(deftest deftype-zero-method-markers
  (is (= "T9" (str (ZeroMethodMarkers. 9)))))

;; --- clojure.lang.ILookup valAt routes through cljw `get` (D-280b) ---

(deftype RemapLookup [m]
  clojure.lang.ILookup
  (valAt [this k] (get m k)))

(deftest protocol-remap-ilookup-get
  (is (= 1 (get (RemapLookup. {:a 1}) :a))))

(deftype RemapLookupArity [m]
  clojure.lang.ILookup
  (valAt [this k] (get m k))
  (valAt [this k nf] (get m k nf)))

(deftest protocol-remap-ilookup-arity
  (is (= [1 nil] [(get (RemapLookupArity. {:a 1}) :a)
                  (get (RemapLookupArity. {:a 1}) :z)])))

;; --- clojure.lang.IPersistentMap splits across target protocols (D-280c) ---

(deftype MultiTargetMap [m]
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (assoc [this k v] (MultiTargetMap. (assoc m k v)))
  (containsKey [this k] (contains? m k))
  (seq [this] (seq m))
  (without [this k] (MultiTargetMap. (dissoc m k)))
  (empty [this] (MultiTargetMap. {}))
  (cons [this e] (MultiTargetMap. (conj m e)))
  clojure.lang.ILookup
  (valAt [this k] (get m k)))

(deftest protocol-remap-ipersistentmap-multitarget
  (let [x (MultiTargetMap. {:a 1})]
    (is (= [1 true 1 2 1]
           [(count x)
            (contains? x :a)
            (get x :a)
            (get (assoc x :b 2) :b)
            (count (dissoc (assoc x :b 2) :a))]))))

;; --- Reversible / IPersistentStack route via the modeled protocols ---

(deftype RemapReversible [v]
  clojure.lang.Reversible
  (rseq [this] (reverse v)))

(deftest protocol-remap-reversible-rseq
  (is (= '(3 2 1) (rseq (RemapReversible. [1 2 3])))))

(deftype RemapStack [v]
  clojure.lang.IPersistentStack
  (peek [this] (last v))
  (pop [this] (RemapStack. (butlast v))))

(deftest protocol-remap-ipersistentstack-peek-pop
  (let [s (RemapStack. [1 2 3])]
    (is (= [3 [1 2]] [(peek s) (vec (.-v (pop s)))]))))

;; --- Object equals / hashCode override the defaults (D-280d1) ---

(deftype EqualsByValue [v]
  Object
  (equals [this o] (= v (.-v o))))

(deftest object-equals-same-type
  (is (= [true false] [(= (EqualsByValue. 1) (EqualsByValue. 1))
                       (= (EqualsByValue. 1) (EqualsByValue. 2))])))

(deftype HashByValue [v]
  Object
  (hashCode [this] (* v 100)))

(deftest object-hashcode
  (is (= 700 (hash (HashByValue. 7)))))

(deftype NoEquals [v])

(deftest deftype-no-equals-keeps-identity
  (is (= [false true] [(= (NoEquals. 1) (NoEquals. 1))
                       (let [x (NoEquals. 1)] (= x x))])))

;; Object methods declared inside the IPersistentMap section still route to
;; the Object method-family (D-280d1b, the priority-map shape).
(deftype ObjectMethodsInMapSection [m]
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (equals [this o] (= m (.-m o)))
  (hashCode [this] (* (count m) 1000)))

(deftest object-methods-in-ipersistentmap-section
  (is (= [true false 1000 1]
         [(= (ObjectMethodsInMapSection. {:x 1}) (ObjectMethodsInMapSection. {:x 1}))
          (= (ObjectMethodsInMapSection. {:x 1}) (ObjectMethodsInMapSection. {:y 2}))
          (hash (ObjectMethodsInMapSection. {:x 1}))
          (count (ObjectMethodsInMapSection. {:x 1}))])))

;; IHashEq/hasheq is preferred over Object/hashCode (D-280d5).
(deftype HasheqPreferred [v]
  Object
  (hashCode [this] 1)
  clojure.lang.IHashEq
  (hasheq [this] (* v 7)))

(deftest ihasheq-hasheq-preferred
  (is (= [63 0] [(hash (HasheqPreferred. 9)) (hash (HasheqPreferred. 0))])))

;; equiv (clj collection =) and entryAt register and dispatch (D-280d8).
(deftype EquivEntryAt [m]
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (equiv [this o] (= m (.-m o)))
  (entryAt [this k] [k (get m k)]))

(deftest equiv-same-type-and-entry-at
  (is (= [true false 1] [(= (EquivEntryAt. {:a 1}) (EquivEntryAt. {:a 1}))
                         (= (EquivEntryAt. {:a 1}) (EquivEntryAt. {:a 2}))
                         (count (EquivEntryAt. {:a 1}))])))

;; --- clojure.lang.Sorted registers and dispatches all four methods (D-280d4) ---

(deftype RemapSorted [m]
  clojure.lang.Sorted
  (comparator [this] :cmp)
  (entryKey [this e] (first e))
  (seq [this ascending] (if ascending :asc :desc))
  (seqFrom [this k ascending] [k ascending]))

(deftest protocol-remap-sorted
  (let [s (RemapSorted. {})]
    (is (= [:cmp :a :asc [:k false]]
           [(-sorted-comparator s)
            (-entry-key s [:a 1])
            (-sorted-seq s true)
            (-sorted-seq-from s :k false)]))))

;; --- IFn (multi-arity invoke) + IObj (D-280d6/d7) ---

(deftype RemapIFnIObj [v]
  clojure.lang.IFn
  (invoke [this k] (get v k))
  (invoke [this k nf] (get v k nf))
  clojure.lang.IObj
  (meta [this] :my-meta)
  (withMeta [this m] (RemapIFnIObj. v)))

(deftest protocol-remap-ifn-iobj
  (let [f (RemapIFnIObj. {:a 1})]
    (is (= [1 :def :my-meta] [(-invoke f :a) (-invoke f :z :def) (-meta f)]))))

;; The call switch (shared treeWalkCall, so both backends) consults IFn/-invoke,
;; making the instance callable in operator position (D-280d6 functional).
(deftype CallableIFn [m]
  clojure.lang.IFn
  (invoke [this k] (get m k))
  (invoke [this k nf] (get m k nf)))

(deftest ifn-deftype-callable
  (let [f (CallableIFn. {:a 1})]
    (is (= [1 :default '(1 nil)] [(f :a) (f :z :default) (map f [:a :z])]))))

;; meta / with-meta consult IObj on a deftype (D-280d7 functional).
(deftype MetaCarrier [m _meta]
  clojure.lang.IObj
  (meta [this] _meta)
  (withMeta [this nm] (MetaCarrier. m nm)))

(deftest iobj-meta-with-meta
  (let [o (MetaCarrier. {:a 1} {:tag :orig})]
    (is (= [{:tag :orig} {:tag :new}] [(meta o) (meta (with-meta o {:tag :new}))]))))

;; --- clojure.core.protocols/IKVReduce dispatches kv-reduce (D-282) ---

(deftype KVReducer [m]
  clojure.core.protocols/IKVReduce
  (kv-reduce [this f init] (reduce-kv f init m)))

(deftest core-protocols-ikvreduce
  (is (= 3 (clojure.core.protocols/kv-reduce
            (KVReducer. {:a 1 :b 2}) (fn [acc k v] (+ acc v)) 0))))

;; --- host_inert java.util.Map + java.lang.Iterable load alongside
;; clojure.lang.*: the clojure.lang methods route, the java ones stay inert (D-281) ---

(deftype InertJavaFamily [m]
  clojure.lang.ILookup
  (valAt [this k] (get m k))
  clojure.lang.IPersistentMap
  (count [this] (count m))
  java.util.Map
  (size [this] (count m))
  (put [this k v] (throw (ex-info "immutable" {})))
  java.lang.Iterable
  (iterator [this] nil))

(deftest host-inert-java-util-map-iterable
  (let [x (InertJavaFamily. {:a 1 :b 2})]
    (is (= [2 1 2] [(count x) (get x :a) (.size x)]))))

;; --- clj-name `.method` dot-calls resolve on a protocol_remap deftype:
;; it registers under BOTH the cljw name (core fns) and the clj name (dot) (D-283) ---

(deftype DotCallable [m]
  clojure.lang.ILookup
  (valAt [this k] (get m k))
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (assoc [this k v] (DotCallable. (assoc m k v))))

(deftest protocol-remap-clj-name-dotcall
  (let [x (DotCallable. {:a 1})]
    (is (= [1 1 2] [(get x :a) (.valAt x :a) (count (.assoc x :b 2))]))))

;; --- (MapEntry. k v) constructs cljw's 2-vector entry (D-284) ---

(deftest map-entry-ctor
  (is (= [[:a 1] :a 2] [(clojure.lang.MapEntry. :a 1)
                        (key (clojure.lang.MapEntry. :a 1))
                        (val (new clojure.lang.MapEntry :b 2))])))

;; --- keys/vals derive from seq when the map deftype has no -keys impl (D-285) ---

(deftype SeqOnlyMap [m]
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (seq [this] (seq m)))

(deftest keys-vals-seq-derive
  (let [x (SeqOnlyMap. {:a 1 :b 2})]
    (is (= ['(:a :b) '(1 2)] [(keys x) (vals x)]))))

;; --- bare IHashEq + the java.util collection host_inert family (D-286a) ---

(deftype BareIHashEq [v]
  IHashEq
  (hasheq [this] (* v 5))
  java.util.Set
  (size [this] v)
  java.util.List
  (get [this i] i))

(deftest bare-ihasheq-java-util-family
  (is (= [20 9] [(hash (BareIHashEq. 4)) (.size (BareIHashEq. 9))])))

;; --- java.io.Closeable host_inert: a declared `close` body is accepted and
;; recorded (never dispatched), and the real protocol method still works (D-291) ---

(defprotocol ReadContents (rc [r]))

(deftype StringReaderish [s]
  ReadContents
  (rc [this] s)
  java.io.Closeable
  (close [this] :closed))

(deftest closeable-host-inert-with-body
  (is (= [:x :closed] [(rc (->StringReaderish :x)) (.close (->StringReaderish :y))])))

;; --- extend-type with MULTIPLE protocol sections in one form (D-292) ---

(defprotocol MultiP1 (m1 [x]))
(defprotocol MultiP2 (m2 [x]))
(defprotocol MultiP3 (m3 [x]))

(extend-type java.lang.String
  MultiP1
  (m1 [x] 1)
  MultiP2
  (m2 [x] 2)
  MultiP3
  (m3 [x] 3))

(deftest extend-type-multi-protocol
  (is (= [1 2 3] [(m1 "a") (m2 "b") (m3 "c")])))
