;; Dispatch: multimethods, protocols, records. The printed forms of a record and
;; of a protocol-satisfying value are part of the user-visible surface.
(defmulti area :shape)
(defmethod area :circle [{:keys [r]}] (* 3 r r))
(defmethod area :rect [{:keys [w h]}] (* w h))
(defmethod area :default [_] :unknown)
(prn (area {:shape :circle :r 2}) (area {:shape :rect :w 2 :h 3}) (area {:shape :blob}))

(defprotocol Greet (greet [this] [this loud?]))
(defrecord Person [name]
  Greet
  (greet [this] (str "hi " (:name this)))
  (greet [this loud?] (if loud? "HI" (greet this))))
(def p (->Person "ada"))
(prn (greet p) (greet p true))
(prn (:name p) (map->Person {:name "bob"}))
(prn (satisfies? Greet p) (instance? Person p))
