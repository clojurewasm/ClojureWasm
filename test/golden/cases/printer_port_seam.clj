;; The two rt/env-fed print paths: `print-method` override consult and the
;; map-style render of an IPersistentMap-declaring deftype. Both reach the VM
;; from inside the otherwise-pure `printValue` recursion, so this case pins
;; what they render — including under the *print-* limits, which is where the
;; two paths differ from the native one.
(deftype Pt [x y])
(defmethod print-method Pt [o w] (.write w "#PT"))
(deftype Box [v])
(defmethod print-method Box [o w] (.write w "Box<") (print-method (.-v o) w) (.write w ">"))

;; An override fires directly, and per-element inside every native collection.
(prn (Pt. 1 2))
(prn [(Pt. 1 2) 9 {:k (Pt. 3 4)}])
(prn #{(Pt. 1 2)})
(prn (list (Pt. 1 2) (Pt. 3 4)))

;; A user method recursing `(print-method child w)` lands on the native default.
(prn (Box. 42))
(prn (Box. [1 2 3]))
(prn (Box. (Box. (Pt. 1 2))))

;; The limits inside an override. clj 1.12 renders these as
;;   Box<[1 2 ...]> / Box<[1 #]> / [Box<[1 2 ...]> 7 ...] /
;;   Box<^{:k :v} [1]> / Box<{:a 1, :b 2, ...}>
(prn (binding [*print-length* 2] (pr-str (Box. [1 2 3 4 5]))))
(prn (binding [*print-level* 1] (pr-str (Box. [1 [2 [3]]]))))
(prn (binding [*print-length* 2] (pr-str [(Box. [1 2 3 4 5]) 7 8 9])))
(prn (binding [*print-meta* true] (pr-str (Box. (with-meta [1] {:k :v})))))
(prn (binding [*print-length* 2] (pr-str (Box. {:a 1 :b 2 :c 3 :d 4}))))
;; …and are restored: an unbound print after a bound one is unlimited again.
(prn (do (binding [*print-length* 2] (pr-str (Box. [1 2 3 4 5])))
         (pr-str (Box. [1 2 3 4 5]))))

;; An IPersistentMap-declaring deftype renders map-style from its -seq, and
;; that path honours the limits too (clj: {:a 1, ...} / {:a #}).
(deftype Pm [m]
  clojure.lang.IPersistentMap
  (count [_] (count m))
  (seq [_] (seq m))
  (assoc [_ k v] (Pm. (assoc m k v))))
(prn (Pm. {:a 1 :b 2}))
(prn (binding [*print-length* 1] (pr-str (Pm. {:a 1 :b 2 :c 3}))))
(prn (binding [*print-level* 1] (pr-str (Pm. {:a {:b 1}}))))

;; An IPersistentMap deftype reached from INSIDE an override. clj renders
;; Box<{:a 1}> in both positions; the map-style render needs rt/env, which
;; today only the printResult entry supplies — so the nested-in-a-vector form
;; (which routes through printResult) and the bare form disagree.
(prn (Box. (Pm. {:a 1})))
(prn [(Box. (Pm. {:a 1}))])
;; A lazy seq inside an override still realizes (clj: Box<(2 3 4)>).
(prn (Box. (map inc [1 2 3])))
(prn (Box. {:k (map inc [1 2])}))
;; Is the map-style deftype a *print-level* nesting level? clj: yes.
;; clj renders [{:a #}] and # respectively.
(prn (binding [*print-level* 2] (pr-str [(Pm. {:a {:b 1}})])))
(prn (binding [*print-level* 0] (pr-str (Pm. {:a 1}))))

;; A record's `{…}` body is its own *print-level* nesting level, and the
;; `#ns.Name` tag prints OUTSIDE the cut. clj renders, in order:
;;   #user.R#   #user.R{:a #}   [#user.R{:a #}]   {:k #user.R#}
(defrecord R [a])
(prn (binding [*print-level* 0] (pr-str (R. {:x 1}))))
(prn (binding [*print-level* 1] (pr-str (R. {:x 1}))))
(prn (binding [*print-level* 2] (pr-str [(R. {:x 1})])))
(prn (binding [*print-level* 1] (pr-str {:k (R. {:x 1})})))
;; *print-length* still reaches a record's field values.
(prn (binding [*print-length* 1] (pr-str (R. [1 2 3]))))
